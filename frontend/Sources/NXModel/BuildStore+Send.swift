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

@MainActor private final class DriveCheckTracker {
    var generation: UInt64 = 0
    var cachedInspections: [String: DriveCopy.TransferInspection] = [:]
    var inflightKeys: Set<String> = []
}

@MainActor private let driveCheckTrackers = NSMapTable<BuildStore, DriveCheckTracker>.weakToStrongObjects()

extension BuildStore {
    private var driveTracker: DriveCheckTracker {
        if let existing = driveCheckTrackers.object(forKey: self) { return existing }
        let created = DriveCheckTracker()
        driveCheckTrackers.setObject(created, forKey: self)
        return created
    }

    @discardableResult
    private func bumpDriveCheckGeneration() -> UInt64 {
        let tracker = driveTracker
        tracker.generation &+= 1
        tracker.cachedInspections.removeAll()
        tracker.inflightKeys.removeAll()
        return tracker.generation
    }

    nonisolated private static func inspectionCacheKey(folder: String, source: TransferSource) -> String {
        "\(folder)\n\(source.titleID.uppercased())\n\(source.name)\n\(source.archive)"
    }

    /// The title ID of the game whose data the last build packed (from `.titleid`, or a legacy `<TitleID>` folder name).
    package var packedTitleID: String {
        guard !archivePath.isEmpty else { return "" }
        if let raw = try? String(contentsOfFile: archivePath + "/.titleid", encoding: .utf8) {
            let marker = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !marker.isEmpty { return marker }
        }
        if let retry = shellRetry, retry.archive == archivePath, !retry.titleID.isEmpty {
            return retry.titleID
        }
        let folderName = (archivePath as NSString).lastPathComponent
        if folderName.hasSuffix(")"), let open = folderName.lastIndex(of: "(") {
            let candidate = String(folderName[folderName.index(after: open)..<folderName.index(before: folderName.endIndex)])
            if candidate.count == 16, candidate.utf8.allSatisfy({
                ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9"))
                    || ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "f"))
                    || ($0 >= UInt8(ascii: "A") && $0 <= UInt8(ascii: "F"))
            }) {
                return candidate
            }
        }
        return folderName
    }

    /// Game name associated with `archivePath` when known, or empty for an unnamed legacy `<TitleID>` archive folder.
    private var effectivePackedGameName: String {
        let explicit = packedGameName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty { return explicit }
        guard !archivePath.isEmpty else { return "" }
        let folderName = (archivePath as NSString).lastPathComponent
        let tid = packedTitleID
        guard !folderName.isEmpty, !tid.isEmpty, folderName.caseInsensitiveCompare(tid) != .orderedSame else { return "" }
        let suffix = " (\(tid.uppercased()))"
        if folderName.uppercased().hasSuffix(suffix), folderName.count > suffix.count {
            return String(folderName.dropLast(suffix.count))
        }
        return folderName
    }

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
        beginOperation(.sendingGameData, game: effectivePackedGameName, titleID: packedTitleID, destination: .target)
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

    /// Total transfer size of the archive files for one `TransferSource`.
    package func transferSourceBytes(_ source: TransferSource) -> Int64 {
        let transfer = ShellInstall.transferSources(archive: source.archive, titleID: source.titleID)
        return transfer.sizes.values.reduce(Int64(0)) { partial, value in
            let (sum, overflow) = partial.addingReportingOverflow(value)
            return overflow ? Int64.max : sum
        }
    }

    /// Pure read-only volume and trailer-delta check across `sources` targeting `folder` (single pass per game, never mutating the drive).
    nonisolated private static func computeDriveBatchState(
        for sources: [TransferSource],
        folder: String
    ) -> (state: DriveState?, inspections: [String: DriveCopy.TransferInspection]) {
        guard !folder.isEmpty, !sources.isEmpty else { return (nil, [:]) }
        var inspections: [String: DriveCopy.TransferInspection] = [:]
        var list: [DriveCopy.TransferInspection] = []
        list.reserveCapacity(sources.count)
        for item in sources {
            let info = DriveCopy.inspectTransfer(archive: item.archive, name: item.name, titleID: item.titleID, inFolder: folder)
            inspections[inspectionCacheKey(folder: folder, source: item)] = info
            list.append(info)
        }
        return (assembleDriveState(from: list, folder: folder), inspections)
    }

    nonisolated private static func assembleDriveState(from list: [DriveCopy.TransferInspection], folder: String) -> DriveState? {
        guard !folder.isEmpty, !list.isEmpty else { return nil }
        var totalNeeded: Int64 = 0
        var totalNetSpace: Int64 = 0
        var maxSingleFile: Int64 = 0
        for info in list {
            let (sumNeeded, overNeeded) = totalNeeded.addingReportingOverflow(info.bytesToCopy)
            totalNeeded = overNeeded ? Int64.max : sumNeeded
            let (sumNet, overNet) = totalNetSpace.addingReportingOverflow(info.netSpaceNeeded)
            totalNetSpace = overNet ? Int64.max : sumNet
            if info.largestFile > maxSingleFile { maxSingleFile = info.largestFile }
        }
        guard let volume = DriveCopy.volume(at: folder) else {
            return DriveState(volume: nil, needed: totalNeeded, problem: nil)
        }
        let problem: DriveCopy.Problem?
        if volume.readOnly {
            problem = .readOnly
        } else if DriveCopy.fileSystemName(volume.fileSystem) == "FAT32", maxSingleFile > DriveCopy.fat32FileLimit {
            problem = .fat32(largest: maxSingleFile)
        } else if totalNetSpace > volume.freeBytes {
            problem = .noSpace(needed: totalNetSpace, free: volume.freeBytes)
        } else {
            problem = nil
        }
        return DriveState(volume: volume, needed: totalNeeded, problem: problem)
    }

    /// Combined read-only volume check across multiple `TransferSource` items targeting `folder` (never renaming or writing on the drive).
    package func driveBatchState(for sources: [TransferSource], folder: String? = nil) -> DriveState? {
        let targetFolder = folder ?? devices.driveFolder
        guard !targetFolder.isEmpty, !sources.isEmpty else { return nil }
        let tracker = driveTracker
        let gen = tracker.generation
        var list: [DriveCopy.TransferInspection] = []
        list.reserveCapacity(sources.count)
        var asyncMisses: [TransferSource] = []
        for item in sources {
            let key = Self.inspectionCacheKey(folder: targetFolder, source: item)
            if let cached = tracker.cachedInspections[key] {
                list.append(cached)
                continue
            }
            let srcImgSize = RomFSArchive.primaryImagePath(in: item.archive)
                .flatMap { (try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? NSNumber)?.int64Value } ?? 0
            if srcImgSize > (16 << 20) {
                if !tracker.inflightKeys.contains(key) {
                    tracker.inflightKeys.insert(key)
                    asyncMisses.append(item)
                }
                let fallbackBytes = transferSourceBytes(item)
                let dest = DriveCopy.destination(folder: targetFolder, name: item.name, titleID: item.titleID)
                list.append(.init(destination: dest, bytesToCopy: fallbackBytes, netSpaceNeeded: fallbackBytes, largestFile: fallbackBytes))
            } else {
                let info = DriveCopy.inspectTransfer(archive: item.archive, name: item.name, titleID: item.titleID, inFolder: targetFolder)
                tracker.cachedInspections[key] = info
                list.append(info)
            }
        }
        if !asyncMisses.isEmpty {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var computed: [String: DriveCopy.TransferInspection] = [:]
                for item in asyncMisses {
                    let key = Self.inspectionCacheKey(folder: targetFolder, source: item)
                    computed[key] = DriveCopy.inspectTransfer(archive: item.archive, name: item.name, titleID: item.titleID, inFolder: targetFolder)
                }
                hop {
                    guard let self else { return }
                    let current = self.driveTracker
                    guard current.generation == gen else { return }
                    for (k, v) in computed {
                        current.cachedInspections[k] = v
                        current.inflightKeys.remove(k)
                    }
                    self.objectWillChange.send()
                }
            }
        }
        return Self.assembleDriveState(from: list, folder: targetFolder)
    }

    /// Asynchronously evaluates the chosen drive folder on a background queue and publishes the result if `driveCheckGeneration` still matches.
    package func refreshDrive() {
        let folder = devices.driveFolder
        let gen = bumpDriveCheckGeneration()
        guard !folder.isEmpty else { drive = nil; return }
        let sources: [TransferSource]
        if !archivePath.isEmpty {
            sources = [TransferSource(titleID: packedTitleID, name: effectivePackedGameName, archive: archivePath)]
        } else {
            sources = sharedAppDataSources()
        }
        guard !sources.isEmpty else { drive = nil; return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.computeDriveBatchState(for: sources, folder: folder)
            hop {
                guard let self else { return }
                let tracker = self.driveTracker
                guard tracker.generation == gen, self.devices.driveFolder == folder else { return }
                for (k, v) in result.inspections { tracker.cachedInspections[k] = v }
                self.drive = result.state
            }
        }
    }

    /// Copies the game data into `<folder>/<SafeName>/` (or `<folder>/<TitleID>/` when unnamed), with progress.
    package func copyToDrive() {
        guard canSendGameData, !devices.driveFolder.isEmpty else { return }
        if let existing = drive {
            guard existing.problem == nil, existing.volume != nil else { return }
        }
        copySourcesToDrive([TransferSource(titleID: packedTitleID, name: effectivePackedGameName, archive: archivePath)], singleGame: true)
    }

    /// Copies the checked games from `sharedAppDataSources()` into `<driveFolder>/<SafeName>/` sequentially on a background queue.
    package func copySelectedToDrive(titleIDs: Set<String>) {
        guard !running, !devices.driveFolder.isEmpty else { return }
        let wanted = Set(titleIDs.map { $0.uppercased() })
        let chosen = sharedAppDataSources().filter { wanted.contains($0.titleID.uppercased()) }
        guard !chosen.isEmpty else { return }
        copySourcesToDrive(chosen, singleGame: chosen.count == 1)
    }

    private func copySourcesToDrive(_ sources: [TransferSource], singleGame: Bool) {
        guard let first = sources.first else { return }
        let folder = devices.driveFolder, cancel = driveCancel
        guard !folder.isEmpty else { return }
        _ = bumpDriveCheckGeneration()
        let firstDisplay = first.name.isEmpty ? first.titleID : first.name
        buildingGame = false; runningTarget = BuildTarget.ios
        beginOperation(.sendingGameData, game: singleGame ? first.name : "\(sources.count)", titleID: first.titleID, destination: .folder)
        running = true; done = false; doneNote = ""; failure = nil; stages = []
        driveBatchLabel = singleGame ? first.name : "1/\(sources.count) · \(firstDisplay)"
        driveCancel.set(false)
        send = .copying(done: 0, total: 0)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let preflight = Self.computeDriveBatchState(for: sources, folder: folder).state
            guard let preflight, preflight.problem == nil, preflight.volume != nil else {
                hop {
                    guard let self else { return }
                    self.running = false
                    self.driveBatchLabel = ""
                    self.send = .idle
                    self.drive = preflight
                }
                return
            }
            let prepared: [(source: TransferSource, destination: String, sizes: [String: Int64], origins: [String: String], needed: Int64)] = sources.map { src in
                let dest = DriveCopy.upgradeLegacyFolder(folder: folder, name: src.name, titleID: src.titleID)
                let transfer = DriveCopy.transferFiles(archive: src.archive, name: src.name, titleID: src.titleID, destination: dest)
                let have = ShellInstall.localFiles(in: dest)
                let needed = DriveCopy.bytesToCopy(files: transfer.sizes, have: have, archive: src.archive, origins: transfer.origins, destination: dest)
                return (src, dest, transfer.sizes, transfer.origins, needed)
            }
            let overallTotal = prepared.reduce(Int64(0)) { partial, item in
                let (sum, overflow) = partial.addingReportingOverflow(item.needed)
                return overflow ? Int64.max : sum
            }
            hop {
                if !cancel.value, case .copying = self?.send {
                    self?.send = .copying(done: 0, total: overallTotal)
                }
            }
            var completedBytes: Int64 = 0
            var lastDest = prepared.first?.destination ?? DriveCopy.destination(folder: folder, name: first.name, titleID: first.titleID)
            var failed: String?
            for (index, item) in prepared.enumerated() {
                if cancel.value { failed = ""; break }
                let itemName = item.source.name.isEmpty ? item.source.titleID : item.source.name
                let label = singleGame ? item.source.name : "\(index + 1)/\(prepared.count) · \(itemName)"
                hop { self?.driveBatchLabel = label }
                lastDest = item.destination
                let baseDone = completedBytes
                do {
                    try DriveCopy.copy(
                        archive: item.source.archive,
                        files: item.sizes,
                        origins: item.origins,
                        to: item.destination,
                        name: item.source.name,
                        titleID: item.source.titleID,
                        progress: { itemDone, _ in
                            let (sum, over) = baseDone.addingReportingOverflow(itemDone)
                            let current = min(overallTotal, over ? Int64.max : sum)
                            hop {
                                if case .copying = self?.send {
                                    self?.send = .copying(done: current, total: overallTotal)
                                }
                            }
                        },
                        cancelled: { cancel.value }
                    )
                    let (sum, over) = baseDone.addingReportingOverflow(item.needed)
                    completedBytes = min(overallTotal, over ? Int64.max : sum)
                } catch DriveCopy.CopyError.cancelled {
                    failed = ""
                    break
                } catch {
                    failed = error.localizedDescription
                    break
                }
            }
            hop {
                guard let self else { return }
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
