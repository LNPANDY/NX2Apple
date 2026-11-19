import Foundation
import NXCore

// The operation that runs (LNPANDY/NX2Apple#676, #1059). `target` and the rows belong to the Build form and change while the work
// runs. `operation` is written once when the work starts, so the activity line and the library name what really runs.

extension BuildStore {
    /// Where the work goes, as the store knows it when the work starts.
    package enum OperationPlace {
        case target
        case folder
        case none
    }

    func beginOperation(_ kind: ActiveOperation.Kind, game: String?, titleID: String?, destination place: OperationPlace) {
        var destination: ActiveOperation.Destination?
        switch place {
        case .target:
            if runningTarget == BuildTarget.mac { destination = .thisMac }
            else if !devices.installDevice.isEmpty { destination = .device(devices.deviceName(devices.installDevice)) }
        case .folder:
            let name = (devices.driveFolder as NSString).lastPathComponent
            if !name.isEmpty { destination = .folder(name) }
        case .none:
            break
        }
        operation = ActiveOperation(kind: kind, game: game?.isEmpty == false ? game : nil, titleID: titleID, destination: destination)
    }

    /// The name of the game whose data or framework the shared-app actions work on: the install hand-off's, else the form's.
    var packedGameName: String { shellRetry?.name ?? gameName }

    /// The operation line for the activity bar and the Builds page: "<operation> · <game> · <destination>".
    package var operationTitle: String? { operation?.title(t) }
}

// The queue's way into the build (LNPANDY/NX2Apple#943): an entry's snapshot becomes the form, then the build starts as if the player
// pressed it. When the player stages a queue batch first, starting it keeps each job's platform and applies the shared iOS delivery options.
extension BuildStore {
    /// True when the build queue holds waiting entries that have not started yet (or are waiting behind a running or paused build).
    package var hasQueuedBuilds: Bool { queuedCount > 0 }

    private var iosExportsShell: Bool {
        queuedExportIPA ?? devices.exportIPA
    }

    private var iosExportsOneGame: Bool {
        iosExportsShell && (queuedExportOneGame ?? devices.exportOneGame)
    }

    private var iosExportsFramework: Bool {
        iosExportsShell && !iosExportsOneGame && (queuedExportFramework ?? devices.exportFramework)
    }

    private var iosPackagesSharedApp: Bool {
        !iosExportsOneGame && !iosExportsFramework
    }

    private var iosInstallsDirectly: Bool {
        !devices.installDevice.isEmpty && !devices.signingTeam.isEmpty
    }

    private func effectiveQueuedTarget(for entry: QueueEntry) -> String {
        BuildTarget.normalized(entry.target)
    }

    private var queueHasIOSTarget: Bool {
        guard hasQueuedBuilds else { return false }
        return queue?.queued.contains { effectiveQueuedTarget(for: $0) != BuildTarget.mac } ?? false
    }

    /// True when a staged queue targets iPhone/iPad direct install without a device and signing team chosen yet.
    package var queueNeedsDevice: Bool {
        queueHasIOSTarget && !iosExportsShell && !iosInstallsDirectly
    }

    /// Whether the Build page's primary Start button (or step 1's Build & export) can start right now.
    package var canStartBuildOrQueue: Bool {
        guard !running else { return false }
        if hasQueuedBuilds {
            return (usesExternalUpstreamRepo || repo.isRepo) && deps.allPresent && !queueNeedsDevice
        }
        return canBuild && keyProblem == nil
    }

    /// Starts the staged jobs on their saved platforms with the chosen iOS install/export mode, or starts a single-game build when no
    /// entries are waiting in the queue.
    package func startBuildOrQueue() {
        guard !running else { return }
        if hasQueuedBuilds, let queue {
            guard usesExternalUpstreamRepo || repo.isRepo, deps.allPresent else { return }
            if queueNeedsDevice {
                doneNote = t("shell.needsDevice")
                done = false
                return
            }
            let hasIOS = queueHasIOSTarget
            if hasIOS, iosPackagesSharedApp {
                if let why = shellRootProblem() {
                    doneNote = why
                    done = false
                    return
                }
                let rebuilding = Set(
                    queue.queued
                        .filter { effectiveQueuedTarget(for: $0) != BuildTarget.mac }
                        .map(\.titleID)
                )
                if askAboutStaleFrameworks(except: rebuilding, then: { [weak self] in self?.startBuildOrQueue() }) {
                    return
                }
            }
            let packageOnce = hasIOS && iosPackagesSharedApp
            let batchExportsIPA: Bool? = hasIOS ? iosExportsShell : nil
            let batchExportsFramework: Bool? = hasIOS ? iosExportsFramework : nil
            let destination = (!hasIOS || iosExportsShell) ? nil : devices.deviceName(devices.installDevice)
            if hasIOS {
                deferredExportsIPA = iosExportsShell
            }
            if deferredShell.isEmpty {
                queue.start(target: nil, packageAfter: packageOnce, exportIPA: batchExportsIPA, exportFramework: batchExportsFramework, destinationName: destination)
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
        let normalizedTarget = BuildTarget.normalized(entry.target)
        if !entry.outputDirectory.isEmpty {
            outDir = entry.outputDirectory
        }
        target = normalizedTarget
        if normalizedTarget != BuildTarget.mac, let entryExport = entry.exportIPA {
            queuedExportIPA = entryExport
            if entry.exportFramework == true && entryExport {
                queuedExportOneGame = false
                queuedExportFramework = true
            } else {
                queuedExportOneGame = entryExport ? !entry.packageAfter : false
                queuedExportFramework = false
            }
        } else {
            queuedExportIPA = nil
            queuedExportOneGame = nil
            queuedExportFramework = nil
        }
        deferShellPackaging = entry.packageAfter && normalizedTarget != BuildTarget.mac && !exportsOneGame && !exportsFramework
        if deferShellPackaging {
            deferredExportsIPA = entry.exportIPA ?? exportsShell
        }

        if entry.fastRefresh {
            let explicitOutDir: String? = {
                if !entry.outputDirectory.isEmpty { return entry.outputDirectory }
                if let app = entry.existingAppPath, !app.isEmpty {
                    let parent = (app as NSString).deletingLastPathComponent
                    if !parent.isEmpty && parent != "/" { return parent }
                }
                return nil
            }()
            skipStaleCheckForQueuedEntry = false
            selectedTitleID = nil
            done = false
            doneNote = ""
            stages = []
            startFastRefresh(
                titleID: entry.titleID,
                targetName: normalizedTarget,
                outDir: explicitOutDir,
                gameName: entry.name.isEmpty ? nil : entry.name,
                existingMacAppPath: entry.existingAppPath,
                externalImgPath: entry.externalImgPath
            )
            if running { return nil }
            queuedExportIPA = nil
            queuedExportOneGame = nil
            queuedExportFramework = nil
            deferShellPackaging = false
            activeQueuedGameID = nil
            return doneNote.isEmpty ? t("queue.cannotStart") : doneNote
        }

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
        if let extImg = entry.externalImgPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !extImg.isEmpty,
           FileManager.default.fileExists(atPath: extImg) {
            fastRefreshExternalImgPath = extImg
        } else {
            fastRefreshExternalImgPath = nil
        }
        skipStaleCheckForQueuedEntry = true
        selectedTitleID = nil
        done = false
        doneNote = ""
        stages = []
        runBuild()
        if running { return nil }
        fastRefreshExternalImgPath = nil
        queuedExportIPA = nil
        queuedExportOneGame = nil
        queuedExportFramework = nil
        deferShellPackaging = false
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
