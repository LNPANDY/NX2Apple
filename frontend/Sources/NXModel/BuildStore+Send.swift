import Foundation
import Combine
import NXCore

// Step 3 of the export (LNPANDY/NX2Apple#416): the game data into the shared app on a device (the install's own copy step), or onto a
// drive or folder of this Mac for the iPhone's Game data folder (DriveCopy). The IPA is signed and installed by another tool.

/// Where step 3 stands. Every failure names the next step only.
package enum DataSend: Equatable {
    case idle
    /// The copy to the device runs: `done` of `total` bytes, and the connection's note (cable or Wi-Fi) once it is known.
    case sending(done: Int64, total: Int64, note: String)
    /// The game data is in the app named `app`.
    case sent(app: String)
    /// The device lists no copy of the shared app: install the IPA first, or copy with Finder when another tool installed it under its own ID.
    case appNotFound
    /// Several copies of the shared app: the player picks one.
    case chooseApp([InstalledApp])
    /// The device listed the app but refused the copy. `detail` is devicectl's own text, for a bug report. The Finder way is offered.
    case refused(detail: String)
    /// Anything else the copy said (the device is locked, not connected, out of space).
    case failed(String)
    /// The copy to the drive runs.
    case copying(done: Int64, total: Int64)
    /// The game data is on the drive, in this folder.
    case copied(folder: String)
}

extension DataSend {
    /// What step 3 shows when a send to the device ended. `notConnected` is the text for a device that was not connected, so nothing was
    /// copied. A refusal and an app the device does not list are their own states, which offer the Finder way (#491). Every other failure
    /// shows the copy's own sentence (no space, the app list could not be read).
    package static func after(_ result: ShellInstaller.Outcome, notConnected: String) -> DataSend {
        if result.copySkipped { return .failed(notConnected) }
        if result.ok { return .sent(app: result.appName) }
        if !result.apps.isEmpty { return .chooseApp(result.apps) }
        switch result.dataFailure {
        case .appNotFound: return .appNotFound
        case .refused: return .refused(detail: result.detail)
        case .noAppList, nil: return .failed(result.message)
        }
    }

    /// The copy to the device did not work and Finder can do it: the second way, offered only now.
    package var offersFinder: Bool {
        switch self { case .appNotFound, .refused: return true; default: return false }
    }
}

/// The chosen drive folder as the card shows it: its volume, the size the game data needs, and what stops the copy.
package struct DriveState: Equatable {
    package var volume: DriveCopy.Volume?
    package var needed: Int64
    package var problem: DriveCopy.Problem?

    package init(volume: DriveCopy.Volume?, needed: Int64, problem: DriveCopy.Problem?) {
        self.volume = volume; self.needed = needed; self.problem = problem
    }
}

extension BuildStore {
    /// The title ID of the game whose data the last build packed (the archive folder is named after it).
    package var packedTitleID: String { archivePath.isEmpty ? "" : (archivePath as NSString).lastPathComponent }

    /// Step 3 can run once a build packed the game's data and the IPA exists, and nothing else runs.
    package var canSendGameData: Bool { !running && !archivePath.isEmpty && !exportedIPAPath.isEmpty }

    /// Multi-game drive copy is available whenever a drive folder is valid, nothing is running, and at least one game has packed data.
    package var canSelectGamesForDrive: Bool {
        !running && !exportedIPAPath.isEmpty && !devices.driveFolder.isEmpty && !sharedAppDataSources().isEmpty
    }

    /// The device button needs a device too, the drive button a folder without a problem.
    package var canSendToDevice: Bool { canSendGameData && !devices.installDevice.isEmpty }
    package var canCopyToDrive: Bool { canSendGameData && drive != nil && drive?.problem == nil && drive?.volume != nil }

    /// The IPA's file name and size, for step 1.
    package var exportedIPAText: String {
        let size = ((try? FileManager.default.attributesOfItem(atPath: exportedIPAPath)[.size]) as? NSNumber)?.int64Value ?? 0
        return (exportedIPAPath as NSString).lastPathComponent + (size > 0 ? ", " + ShellInstall.sizeText(size) : "")
    }

    // MARK: To the device

    /// Finds the shared app on the device and copies the game data into it with the install's own data step. `bundle` is the copy
    /// the player chose when the device has several.
    package func sendGameData(bundle: String? = nil) {
        guard canSendToDevice else { return }
        buildingGame = false; runningTarget = BuildTarget.ios
        beginOperation(.sendingGameData, game: packedGameName, titleID: packedTitleID, destination: .target)
        stopping = false; stoppedByPlayer = false; installCancel.set(false); installPhaseActive = true
        running = true; done = false; doneNote = ""; failure = nil; stages = []
        send = .sending(done: 0, total: 0, note: "")
        var installer = makeInstaller()
        let target = devices, device = devices.installDevice, cancel = installCancel
        let titleID = packedTitleID, archive = archivePath
        // One click: no question. A device that is not connected cannot be copied to, the player is told instead.
        installer.decideCopy = { [weak self] plan in
            if cancel.value || plan.connection == .notConnected { return .skip }
            hop { if case .sending(let done, let total, _) = self?.send { self?.send = .sending(done: done, total: total, note: plan.connectionText) } }
            return .copy
        }
        installer.copyProgress = { [weak self] done, total in
            hop {
                guard let self, case .sending(_, _, let note) = self.send else { return }
                self.send = .sending(done: done, total: total, note: note)
            }
        }
        let ready = installer
        DispatchQueue.global(qos: .userInitiated).async {
            let result = ready.sendData(titleID: titleID, archive: archive, bundleID: bundle)
            hop {
                self.installPhaseActive = false
                target.copyEnded()
                self.running = false
                if self.stopping {
                    self.stopping = false
                    self.resetProgress(); self.send = .idle; self.doneNote = self.t("msg.stopped")
                    return
                }
                self.send = .after(result, notConnected: String(format: self.t("shell.copyNotConnected"), self.devices.deviceName(device)))
                if case .failed = self.send, !result.copySkipped, let kind = result.failure { self.failure = BuildFailure(kind: kind, gameName: nil) }
            }
        }
    }

    /// What the player drags onto the app in Finder: the game's folder, named after its title ID, with `romfs.img` and the add-on content
    /// beside it, as the copy to the device sends them. The folder and not the image alone, so the add-on content comes along and the
    /// shell's data picker, which picks folders, can pick it. None for one game's own IPA, which holds its data, and before a build packed it.
    package static func finderItem(archive: String, oneGame: Bool) -> String? {
        oneGame || archive.isEmpty ? nil : archive
    }

    /// The failed automatic install owns its archive, even if another game has since been selected.
    /// Export failures use the export's archive. No recovery is offered before a copy fails.
    package var finderArchive: String? {
        if failure?.kind == .shellDataIncomplete {
            return Self.finderItem(archive: shellRetry?.archive ?? "", oneGame: false)
        }
        return send.offersFinder ? Self.finderItem(archive: archivePath, oneGame: false) : nil
    }

    /// The Finder way, after the copy to the device did not work: a Finder window with the game's folder selected, ready to drag.
    package func copyWithFinder(oneGame: Bool) {
        guard !running, !oneGame, let item = finderArchive else { return }
        revealItem(URL(fileURLWithPath: item))
        finderShown = true
    }

    // MARK: To a drive or folder

    /// The folder panel, then what the folder's volume says about the game data.
    package func chooseDriveFolder() {
        guard let folder = chooseFolder() else { return }
        devices.driveFolder = folder
        refreshDrive()
    }

    /// Total transfer size (archive + externalized `msl/` when applicable) for one `TransferSource`.
    package func transferSourceBytes(_ source: TransferSource) -> Int64 {
        let transfer = ShellInstall.transferSources(
            archive: source.archive,
            shellRoot: shellRoot,
            titleID: source.titleID,
            includeExternalMSL: true
        )
        return transfer.sizes.values.reduce(Int64(0)) { partial, value in
            let (sum, overflow) = partial.addingReportingOverflow(value)
            return overflow ? Int64.max : sum
        }
    }

    /// Combined volume check across multiple `TransferSource` items targeting `folder`.
    package func driveBatchState(for sources: [TransferSource], folder: String? = nil) -> DriveState? {
        let targetFolder = folder ?? devices.driveFolder
        guard !targetFolder.isEmpty, !sources.isEmpty else { return nil }
        let root = shellRoot
        var totalNeeded: Int64 = 0
        var maxSingleFile: Int64 = 0
        for item in sources {
            let transfer = ShellInstall.transferSources(
                archive: item.archive,
                shellRoot: root,
                titleID: item.titleID,
                includeExternalMSL: true
            )
            let have = ShellInstall.localFiles(in: DriveCopy.destination(folder: targetFolder, titleID: item.titleID))
            let needed = DriveCopy.bytesToCopy(files: transfer.sizes, have: have)
            let (sum, overflow) = totalNeeded.addingReportingOverflow(needed)
            totalNeeded = overflow ? Int64.max : sum
            if let biggest = transfer.sizes.values.max(), biggest > maxSingleFile {
                maxSingleFile = biggest
            }
        }
        guard let volume = DriveCopy.volume(at: targetFolder) else {
            return DriveState(volume: nil, needed: totalNeeded, problem: nil)
        }
        let problem: DriveCopy.Problem?
        if volume.readOnly {
            problem = .readOnly
        } else if DriveCopy.fileSystemName(volume.fileSystem) == "FAT32", maxSingleFile > DriveCopy.fat32FileLimit {
            problem = .fat32(largest: maxSingleFile)
        } else if totalNeeded > volume.freeBytes {
            problem = .noSpace(needed: totalNeeded, free: volume.freeBytes)
        } else {
            problem = nil
        }
        return DriveState(volume: volume, needed: totalNeeded, problem: problem)
    }

    /// The volume of the chosen folder against the game data the copy still has to write.
    package func refreshDrive() {
        let folder = devices.driveFolder
        guard !folder.isEmpty else { drive = nil; return }
        guard !archivePath.isEmpty else {
            let all = sharedAppDataSources()
            drive = all.isEmpty ? nil : driveBatchState(for: all, folder: folder)
            return
        }
        let transfer = ShellInstall.transferSources(
            archive: archivePath,
            shellRoot: shellRoot,
            titleID: packedTitleID,
            includeExternalMSL: true
        )
        let files = transfer.sizes
        let have = ShellInstall.localFiles(in: DriveCopy.destination(folder: folder, titleID: packedTitleID))
        let needed = DriveCopy.bytesToCopy(files: files, have: have)
        guard let volume = DriveCopy.volume(at: folder) else { drive = DriveState(volume: nil, needed: needed, problem: nil); return }
        drive = DriveState(volume: volume, needed: needed, problem: DriveCopy.problem(files: files, have: have, volume: volume))
    }

    /// A plain file copy of the game data into `<folder>/<title ID>/`, with progress.
    package func copyToDrive() {
        refreshDrive()
        guard canCopyToDrive else { return }
        copySourcesToDrive([TransferSource(titleID: packedTitleID, name: packedGameName, archive: archivePath)], singleGame: true)
    }

    /// Copies the checked games from `sharedAppDataSources()` into `<driveFolder>/<title ID>/` sequentially on a background queue.
    package func copySelectedToDrive(titleIDs: Set<String>) {
        guard !running else { return }
        let wanted = Set(titleIDs.map { $0.uppercased() })
        let chosen = sharedAppDataSources().filter { wanted.contains($0.titleID.uppercased()) }
        guard !chosen.isEmpty else { return }
        let state = driveBatchState(for: chosen)
        drive = state
        guard let state, state.problem == nil, state.volume != nil else { return }
        copySourcesToDrive(chosen, singleGame: chosen.count == 1)
    }

    private func copySourcesToDrive(_ sources: [TransferSource], singleGame: Bool) {
        guard let first = sources.first else { return }
        let folder = devices.driveFolder, root = shellRoot, cancel = driveCancel
        let prepared: [(source: TransferSource, sizes: [String: Int64], origins: [String: String], needed: Int64)] = sources.map { src in
            let transfer = ShellInstall.transferSources(archive: src.archive, shellRoot: root, titleID: src.titleID, includeExternalMSL: true)
            let have = ShellInstall.localFiles(in: DriveCopy.destination(folder: folder, titleID: src.titleID))
            let needed = DriveCopy.bytesToCopy(files: transfer.sizes, have: have)
            return (src, transfer.sizes, transfer.origins, needed)
        }
        let overallTotal = prepared.reduce(Int64(0)) { partial, item in
            let (sum, overflow) = partial.addingReportingOverflow(item.needed)
            return overflow ? Int64.max : sum
        }
        buildingGame = false; runningTarget = BuildTarget.ios
        beginOperation(.sendingGameData, game: singleGame ? first.name : "\(sources.count)", titleID: first.titleID, destination: .folder)
        running = true; done = false; doneNote = ""; failure = nil; stages = []
        driveBatchLabel = singleGame ? first.name : "1/\(sources.count) · \(first.name)"
        driveCancel.set(false)
        send = .copying(done: 0, total: overallTotal)
        DispatchQueue.global(qos: .userInitiated).async {
            var completedBytes: Int64 = 0
            var lastDest = DriveCopy.destination(folder: folder, titleID: first.titleID)
            var failed: String?
            for (index, item) in prepared.enumerated() {
                if cancel.value { failed = ""; break }
                let label = singleGame ? item.source.name : "\(index + 1)/\(prepared.count) · \(item.source.name)"
                hop { self.driveBatchLabel = label }
                let destination = DriveCopy.destination(folder: folder, titleID: item.source.titleID)
                lastDest = destination
                let baseDone = completedBytes
                do {
                    try DriveCopy.copy(
                        archive: item.source.archive,
                        files: item.sizes,
                        origins: item.origins,
                        to: destination,
                        progress: { itemDone, _ in
                            let current = min(overallTotal, baseDone + itemDone)
                            hop {
                                if case .copying = self.send {
                                    self.send = .copying(done: current, total: overallTotal)
                                }
                            }
                        },
                        cancelled: { cancel.value }
                    )
                    completedBytes = min(overallTotal, baseDone + item.needed)
                } catch DriveCopy.CopyError.cancelled {
                    failed = ""
                    break
                } catch {
                    failed = error.localizedDescription
                    break
                }
            }
            hop {
                self.running = false
                self.driveBatchLabel = ""
                if let failed {
                    self.send = failed.isEmpty ? .idle : .failed(String(format: self.t("shell.driveFailed"), failed))
                } else {
                    self.send = .copied(folder: lastDest)
                    self.refreshDrive()
                }
            }
        }
    }

    /// Stop while the copy to the drive runs; the file in progress is dropped, the finished ones stay for the next run.
    package func stopDriveCopy() { driveCancel.set(true) }
}
