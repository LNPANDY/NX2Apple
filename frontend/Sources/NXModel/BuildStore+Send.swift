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

    /// The games whose data step 3 sends, each with its data folder in `archive`: every game of the shared app whose folder is found
    /// on this Mac, and the game this build packed (with the folder it packed now). The copy skips what the destination holds already.
    package var dataToSend: [ShellLibrary.Game] {
        let packed = packedTitleID
        var items = shellGames.filter { $0.archive != nil }
        if !packed.isEmpty {
            if let i = items.firstIndex(where: { $0.titleID.caseInsensitiveCompare(packed) == .orderedSame }) { items[i].archive = archivePath }
            else { items.append(.init(titleID: packed, name: gameName, framework: "", archive: archivePath)) }
        }
        return items
    }

    /// The games of the shared app whose data is on none of the folders this Mac knows: step 3 names them.
    package var gamesWithoutData: [ShellLibrary.Game] {
        let packed = packedTitleID
        return shellGames.filter { $0.archive == nil && $0.titleID.caseInsensitiveCompare(packed) != .orderedSame }
    }

    /// The games step 3 sends: those of `dataToSend` the player left ticked (a game that cannot run on the device, or whose data is
    /// there already, need not go again).
    package var dataSelected: [ShellLibrary.Game] { dataToSend.filter { !sendSkipped.contains($0.titleID.uppercased()) } }

    /// Whether step 3 sends this game's data: the tick of its row.
    package func sends(_ titleID: String) -> Bool { !sendSkipped.contains(titleID.uppercased()) }

    /// Ticks or unticks a game of step 3, then counts the drive's room again for the games left.
    package func setSends(_ titleID: String, _ on: Bool) {
        if on { sendSkipped.remove(titleID.uppercased()) } else { sendSkipped.insert(titleID.uppercased()) }
        refreshDrive()
    }

    /// Step 3 can run once the IPA exists and a ticked game's data is known, and nothing else runs.
    package var canSendGameData: Bool { !running && !exportedIPAPath.isEmpty && !dataSelected.isEmpty }

    /// The folder the Finder way shows: the game whose copy did not work, else the game this build packed.
    package var finderArchive: String { sendArchive.isEmpty ? archivePath : sendArchive }

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
        let items = dataSelected
        buildingGame = false; runningTarget = BuildTarget.ios
        running = true; done = false; doneNote = ""; failure = nil; stages = []
        send = .sending(done: 0, total: 0, note: "")
        sendStop.set(false)
        sendingGame = items.first?.name ?? ""; sendArchive = items.first?.archive ?? ""
        var installer = makeInstaller()
        let target = devices, device = devices.installDevice, stop = sendStop
        // One click: no question. A device that is not connected cannot be copied to, the player is told instead.
        installer.decideCopy = { [weak self] plan in
            if plan.connection == .notConnected { return .skip }
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
            // One game after the other into the same app: the first finds it (or asks which one), the others go to that one. The
            // first game whose copy does not work ends the run, and step 3 shows that game's state.
            var chosen = bundle, appName = "", last: ShellInstaller.Outcome?
            for item in items {
                guard !stop.value, let archive = item.archive else { break }
                hop {
                    self.sendingGame = item.name.isEmpty ? item.titleID : item.name; self.sendArchive = archive
                    if case .sending(_, _, let note) = self.send { self.send = .sending(done: 0, total: 0, note: note) }
                }
                let result = ready.sendData(titleID: item.titleID, archive: archive, bundleID: chosen)
                last = result
                if !result.appName.isEmpty { appName = result.appName }
                guard result.ok, !result.copySkipped else { break }
                if chosen == nil { chosen = result.bundleID }
            }
            hop {
                target.copyEnded()
                self.running = false
                if self.stopping || stop.value {
                    self.stopping = false; stop.set(false)
                    self.resetProgress(); self.send = .idle; self.doneNote = self.t("msg.stopped")
                    return
                }
                guard var result = last else { self.send = .idle; return }
                if result.ok { result.appName = appName }
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

    /// The Finder way, after the copy to the device did not work: a Finder window with the game's folder selected, ready to drag.
    package func copyWithFinder(oneGame: Bool) {
        guard send.offersFinder, let item = Self.finderItem(archive: finderArchive, oneGame: oneGame) else { return }
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

    /// The volume of the chosen folder against the game data the copy still has to write, for every game of step 3 together. Each
    /// game's files go to `<folder>/<title ID>/`, so they are counted under that prefix.
    package func refreshDrive() {
        let folder = devices.driveFolder, items = dataSelected
        guard !folder.isEmpty, !items.isEmpty else { drive = nil; return }
        var files: [String: Int64] = [:], have: [String: Int64] = [:]
        for item in items {
            for (path, size) in ShellInstall.localFiles(in: item.archive ?? "") { files[item.titleID + "/" + path] = size }
            for (path, size) in ShellInstall.localFiles(in: DriveCopy.destination(folder: folder, titleID: item.titleID)) { have[item.titleID + "/" + path] = size }
        }
        let needed = DriveCopy.bytesToCopy(files: files, have: have)
        guard let volume = DriveCopy.volume(at: folder) else { drive = DriveState(volume: nil, needed: needed, problem: nil); return }
        drive = DriveState(volume: volume, needed: needed, problem: DriveCopy.problem(files: files, have: have, volume: volume))
    }

    /// A plain file copy of each game's data into `<folder>/<title ID>/`, one game after the other, with one progress for all.
    package func copyToDrive() {
        refreshDrive()
        guard canCopyToDrive else { return }
        buildingGame = false; runningTarget = BuildTarget.ios
        running = true; done = false; doneNote = ""; failure = nil; stages = []
        driveCancel.set(false)
        let total = drive?.needed ?? 0
        send = .copying(done: 0, total: total)
        let folder = devices.driveFolder, items = dataSelected, cancel = driveCancel
        DispatchQueue.global(qos: .userInitiated).async {
            var failed: String?, before: Int64 = 0, destination = folder
            for item in items {
                guard let archive = item.archive else { continue }
                destination = DriveCopy.destination(folder: folder, titleID: item.titleID)
                let files = ShellInstall.localFiles(in: archive)
                let needed = DriveCopy.bytesToCopy(files: files, have: ShellInstall.localFiles(in: destination))
                let offset = before
                hop { self.sendingGame = item.name.isEmpty ? item.titleID : item.name; self.sendArchive = archive }
                do {
                    try DriveCopy.copy(archive: archive, files: files, to: destination,
                                       progress: { done, _ in hop { if case .copying = self.send { self.send = .copying(done: offset + done, total: total) } } },
                                       cancelled: { cancel.value })
                } catch DriveCopy.CopyError.cancelled { failed = ""; break }
                catch { failed = error.localizedDescription; break }
                before += needed
            }
            hop {
                self.running = false
                if let failed {
                    self.send = failed.isEmpty ? .idle : .failed(String(format: self.t("shell.driveFailed"), failed))
                } else {
                    self.send = .copied(folder: destination)
                    self.refreshDrive()
                }
            }
        }
    }

    /// Stop while the copy to the drive runs; the file in progress is dropped, the finished ones stay for the next run.
    package func stopDriveCopy() { driveCancel.set(true) }
}
