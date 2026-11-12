import Foundation
import NXCore

// The operation that runs (LNPANDY/NX2Apple#676, #1059). `target` and the rows belong to the Build form and change while the work
// runs. `operation` is written once when the work starts, so the activity line and the library name what really runs.

extension BuildStore {
    /// Where the work goes, as the store knows it when the work starts.
    package enum OperationPlace { case target, folder, none }

    func beginOperation(_ kind: ActiveOperation.Kind, game: String?, titleID: String?, destination place: OperationPlace) {
        var destination: ActiveOperation.Destination?
        switch place {
        case .target:
            if runningTarget == BuildTarget.mac { destination = .thisMac }
            else if !devices.installDevice.isEmpty { destination = .device(devices.deviceName(devices.installDevice)) }
        case .folder:
            let name = (devices.driveFolder as NSString).lastPathComponent
            if !name.isEmpty { destination = .folder(name) }
        case .none: break
        }
        operation = ActiveOperation(kind: kind, game: game?.isEmpty == false ? game : nil, titleID: titleID, destination: destination)
    }

    /// The name of the game whose data or framework the shared-app actions work on: the install hand-off's, else the form's.
    var packedGameName: String { shellRetry?.name ?? gameName }

    /// The operation line for the activity bar and the Builds page: "<operation> · <game> · <destination>".
    package var operationTitle: String? { operation?.title(t) }
}

// The queue's way into the build (LNPANDY/NX2Apple#943): an entry's snapshot becomes the form, then the build starts as if the player
// pressed it. When the player stages a queue batch first, starting it applies the Build page's target and shared-app packaging mode.
extension BuildStore {
    /// True when the build queue holds waiting entries that have not started yet (or are waiting behind a running or paused build).
    package var hasQueuedBuilds: Bool { queuedCount > 0 }

    /// True when a staged queue targets iPhone/iPad direct install without a device and signing team chosen yet.
    package var queueNeedsDevice: Bool {
        hasQueuedBuilds && target != BuildTarget.mac && !exportsShell && !installsDirectly
    }

    /// Whether the Build page's primary Start button (or step 1's Build & export) can start right now.
    package var canStartBuildOrQueue: Bool {
        guard !running else { return false }
        if hasQueuedBuilds {
            return repo.isRepo && deps.allPresent && !queueNeedsDevice
        }
        return canBuild && keyProblem == nil
    }

    /// Starts the staged build queue with the player's chosen target and install/export mode, or starts a single-game build when no
    /// entries are waiting in the queue.
    package func startBuildOrQueue() {
        guard !running else { return }
        if hasQueuedBuilds, let queue {
            guard repo.isRepo, deps.allPresent else { return }
            if queueNeedsDevice {
                doneNote = t("shell.needsDevice")
                done = false
                return
            }
            if target != BuildTarget.mac, !exportsOneGame {
                if let why = shellRootProblem() {
                    doneNote = why
                    done = false
                    return
                }
                let rebuilding = Set(queue.queued.map { $0.titleID })
                if askAboutStaleFrameworks(except: rebuilding, then: { [weak self] in self?.startBuildOrQueue() }) {
                    return
                }
            }
            let packageOnce = target != BuildTarget.mac && !exportsOneGame
            let batchExportsIPA = target == BuildTarget.mac ? nil : exportsShell
            let destination = (target == BuildTarget.mac || exportsShell) ? nil : devices.deviceName(devices.installDevice)
            deferredExportsIPA = exportsShell
            if deferredShell.isEmpty {
                queue.start(target: target, packageAfter: packageOnce, exportIPA: batchExportsIPA, destinationName: destination)
            } else {
                queue.resume()
            }
            return
        }
        startBuild()
    }

    /// Starts the entry's build. nil: it runs. A string: why it could not start, which the queue shows on the entry.
    package func startQueued(_ entry: QueueEntry) -> String? {
        guard !running else { return t("queue.cannotStart") }
        activeQueuedGameID = entry.gameID
        if let folder = entry.gameFolder {
            scan(folder: folder)
        } else {
            leaveGameFolder()
            for index in slots.indices {
                slots[index].paths = entry.inputs[slots[index].id] ?? []
                slots[index].problem = ""
            }
            gameDir = (basePath as NSString).deletingLastPathComponent
        }
        if !entry.outputDirectory.isEmpty { outDir = entry.outputDirectory }
        target = entry.target
        if entry.target != BuildTarget.mac, let entryExport = entry.exportIPA {
            queuedExportIPA = entryExport
            queuedExportOneGame = entryExport ? !entry.packageAfter : false
        } else {
            queuedExportIPA = nil
            queuedExportOneGame = nil
        }
        deferShellPackaging = entry.packageAfter && entry.target != BuildTarget.mac && !exportsOneGame
        if deferShellPackaging { deferredExportsIPA = entry.exportIPA ?? exportsShell }
        skipStaleCheckForQueuedEntry = true
        selectedTitleID = nil
        done = false; doneNote = ""; stages = []
        runBuild()
        if running { return nil }
        queuedExportIPA = nil
        queuedExportOneGame = nil
        skipStaleCheckForQueuedEntry = false
        activeQueuedGameID = nil
        return doneNote.isEmpty ? t("queue.cannotStart") : doneNote
    }

    /// Whether the build that just ended counts as a success for the queue, and the reason when it does not.
    package var queueOutcome: (succeeded: Bool, reason: String?, stopped: Bool) {
        let ok = done && failure == nil
        return (ok, ok ? nil : (doneNote.isEmpty ? t("queue.stopped") : doneNote), stoppedByPlayer)
    }
}
