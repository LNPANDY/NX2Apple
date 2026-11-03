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
    /// The device lists no copy of the shared app: install the IPA first.
    case appNotFound
    /// Several copies of the shared app: the player picks one.
    case chooseApp([InstalledApp])
    /// devicectl refused. `detail` is its own text, for a bug report.
    case refused(detail: String)
    /// Anything else the copy said (the device is locked, not connected, out of space).
    case failed(String)
    /// The copy to the drive runs.
    case copying(done: Int64, total: Int64)
    /// The game data is on the drive, in this folder.
    case copied(folder: String)
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
        running = true; done = false; doneNote = ""; failure = nil; stages = []
        send = .sending(done: 0, total: 0, note: "")
        var installer = makeInstaller()
        let target = devices, device = devices.installDevice
        let titleID = packedTitleID, archive = archivePath
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
            let result = ready.sendData(titleID: titleID, archive: archive, bundleID: bundle)
            hop {
                target.copyEnded()
                self.running = false
                if self.stopping {
                    self.stopping = false
                    self.resetProgress(); self.send = .idle; self.doneNote = self.t("msg.stopped")
                    return
                }
                if result.ok && !result.copySkipped {
                    self.send = .sent(app: result.appName.isEmpty ? "" : result.appName)
                } else if result.copySkipped {
                    self.send = .failed(String(format: self.t("shell.copyNotConnected"), self.devices.deviceName(device)))
                } else if !result.apps.isEmpty {
                    self.send = .chooseApp(result.apps)
                } else if result.dataFailure == .appNotFound {
                    self.send = .appNotFound
                } else if result.dataFailure == .refused {
                    self.send = .refused(detail: result.detail)
                } else {
                    if let kind = result.failure { self.failure = BuildFailure(kind: kind, gameName: nil) }
                    self.send = .failed(result.message)
                }
            }
        }
    }

    /// Opens the game's data folder in the Finder, for the way that needs no devicectl.
    package func showGameDataInFinder() {
        guard !archivePath.isEmpty else { return }
        revealFolder(URL(fileURLWithPath: archivePath))
    }

    // MARK: To a drive or folder

    /// The folder panel, then what the folder's volume says about the game data.
    package func chooseDriveFolder() {
        guard let folder = chooseFolder() else { return }
        devices.driveFolder = folder
        refreshDrive()
    }

    /// The volume of the chosen folder against the game data the copy still has to write.
    package func refreshDrive() {
        let folder = devices.driveFolder
        guard !folder.isEmpty, !archivePath.isEmpty else { drive = nil; return }
        let files = ShellInstall.localFiles(in: archivePath)
        let have = ShellInstall.localFiles(in: DriveCopy.destination(folder: folder, titleID: packedTitleID))
        let needed = DriveCopy.bytesToCopy(files: files, have: have)
        guard let volume = DriveCopy.volume(at: folder) else { drive = DriveState(volume: nil, needed: needed, problem: nil); return }
        drive = DriveState(volume: volume, needed: needed, problem: DriveCopy.problem(files: files, have: have, volume: volume))
    }

    /// A plain file copy of the game data into `<folder>/<title ID>/`, with progress.
    package func copyToDrive() {
        refreshDrive()
        guard canCopyToDrive else { return }
        running = true; done = false; doneNote = ""; failure = nil; stages = []
        driveCancel.set(false)
        send = .copying(done: 0, total: drive?.needed ?? 0)
        let folder = devices.driveFolder, titleID = packedTitleID, archive = archivePath, cancel = driveCancel
        let files = ShellInstall.localFiles(in: archive)
        DispatchQueue.global(qos: .userInitiated).async {
            let destination = DriveCopy.destination(folder: folder, titleID: titleID)
            var failed: String?
            do {
                try DriveCopy.copy(archive: archive, files: files, to: destination,
                                   progress: { done, total in hop { if case .copying = self.send { self.send = .copying(done: done, total: total) } } },
                                   cancelled: { cancel.value })
            } catch DriveCopy.CopyError.cancelled { failed = "" }
            catch { failed = error.localizedDescription }
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
