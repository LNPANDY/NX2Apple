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
// pressed it. Nothing here picks another engine, another target or other files than the entry holds.
extension BuildStore {
    /// Starts the entry's build. nil: it runs. A string: why it could not start, which the queue shows on the entry.
    package func startQueued(_ entry: QueueEntry) -> String? {
        guard !running else { return t("queue.cannotStart") }
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
        outDir = entry.outputDirectory
        target = entry.target
        deferShellPackaging = entry.packageAfter && entry.target != BuildTarget.mac
        done = false; doneNote = ""; stages = []
        startBuild()
        if running { return nil }
        return doneNote.isEmpty ? t("queue.cannotStart") : doneNote
    }

    /// Whether the build that just ended counts as a success for the queue, and the reason when it does not.
    package var queueOutcome: (succeeded: Bool, reason: String?, stopped: Bool) {
        let ok = done && failure == nil
        return (ok, ok ? nil : (doneNote.isEmpty ? t("queue.stopped") : doneNote), stoppedByPlayer)
    }
}
