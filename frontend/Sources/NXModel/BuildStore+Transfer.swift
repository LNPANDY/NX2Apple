import Foundation
import Combine
import NXCore

// The shared app's separate actions (LNPANDY/NX2Apple#994, #1036). Build and export (the build, then the IPA), Export IPA (the IPA of
// the frameworks already built, no game is built again), Install (the signed app on the device) and Send game data (a transfer, which
// has its own queue and runs beside a build) are four actions with four effects.

/// A game whose data folder can be sent: the library gives the title ID, the name and the packed folder.
package struct TransferSource: Equatable {
    package var titleID: String
    package var name: String
    package var archive: String

    package init(titleID: String, name: String, archive: String) { self.titleID = titleID; self.name = name; self.archive = archive }
}

/// One game finished during a queued shared-app batch, waiting for the single final IPA export or device install.
package struct DeferredShellGame: Equatable {
    package var gameID: UUID?
    package var framework: String
    package var titleID: String
    package var name: String
    package var archive: String

    package init(gameID: UUID? = nil, framework: String, titleID: String, name: String, archive: String) {
        self.gameID = gameID
        self.framework = framework
        self.titleID = titleID
        self.name = name
        self.archive = archive
    }
}

extension BuildStore {
    // MARK: Export or install without a build

    /// The games whose frameworks the shared app holds and that are still on disk.
    package func builtShellGames() -> [ShellLibrary.Game] {
        var library = ShellLibrary.load(root: shellRoot)
        library.dropMissing()
        return library.games
    }

    /// The IPA of the frameworks that are built can be made again: an IPA target, a built game, and nothing running.
    package var canExportBuiltGames: Bool { !running && exportsShell && !exportsOneGame && !builtShellGames().isEmpty }

    /// The shared app can be signed and installed from the frameworks already built: direct install mode with device and team ready.
    package var canInstallBuiltGames: Bool { !running && installsDirectly && !devices.exportIPA && !builtShellGames().isEmpty }

    /// "Export IPA": the shell's project with every built framework, unsigned, zipped. No game is built or packed again.
    package func exportBuiltGames() {
        guard canExportBuiltGames else { return }
        if askAboutStaleFrameworks(except: Set(), then: { [weak self] in self?.exportBuiltGamesAfterStaleCheck() }) {
            return
        }
        exportBuiltGamesAfterStaleCheck()
    }

    private func exportBuiltGamesAfterStaleCheck() {
        guard canExportBuiltGames, let last = builtShellGames().last else { return }
        exportShell(framework: last.framework, titleID: last.titleID, name: last.name)
    }

    /// "Install built games": signs and installs the shared app from the frameworks already built, without rebuilding any game or
    /// transferring `romfs.img` game data.
    package func installBuiltGames() {
        guard canInstallBuiltGames else { return }
        if askAboutStaleFrameworks(except: Set(), then: { [weak self] in self?.installBuiltGamesAfterStaleCheck() }) {
            return
        }
        installBuiltGamesAfterStaleCheck()
    }

    private func installBuiltGamesAfterStaleCheck() {
        guard canInstallBuiltGames, let last = builtShellGames().last else { return }
        installBuiltShell(framework: last.framework, titleID: last.titleID, name: last.name)
    }

    // MARK: A batch of the queue packages or installs the shared app once

    /// A queued game was built and packed, its app is made or installed once when the batch ends.
    func deferShellPackage(framework: String, titleID: String, name: String, archive: String = "") {
        if deferredShell.isEmpty && !deferShellPackaging {
            deferredExportsIPA = exportsShell
        }
        deferredShell.append(DeferredShellGame(gameID: activeQueuedGameID, framework: framework, titleID: titleID, name: name, archive: archive))
        let noteKey = deferredExportsIPA ? "queue.packageLater" : "queue.installLater"
        finishInstall(nil, note: String(format: t(noteKey), name))
    }

    /// The batch ended: the shared app is exported or signed and installed once from the games that were built. A game that failed is not in it.
    package func packageDeferred() {
        let games = deferredShell
        deferredShell = []
        guard let last = games.last, !running else { return }
        if deferredExportsIPA {
            var library = ShellLibrary.load(root: shellRoot)
            for game in games.dropLast() { library.add(.init(titleID: game.titleID, name: game.name, framework: game.framework)) }
            try? library.save(root: shellRoot)
            exportShell(framework: last.framework, titleID: last.titleID, name: last.name,
                        extraFrameworksToClean: games.dropLast().map(\.framework))
        } else {
            installShellBatch(games)
        }
    }

    // MARK: Send game data

    /// Every game the library holds data for can go to the chosen device.
    package var canSendAllGameData: Bool { transfers != nil && !devices.installDevice.isEmpty && !sharedAppDataSources().isEmpty }

    /// "Send game data" for every game with packed data: one transfer each, for the chosen device. Nothing is built.
    package func sendAllGameData() {
        sendSelectedGameData(titleIDs: Set(sharedAppDataSources().map { $0.titleID.uppercased() }))
    }

    /// Enqueues the checked games from `sharedAppDataSources()` onto `TransferQueueStore` in library order.
    package func sendSelectedGameData(titleIDs: Set<String>) {
        guard canSendAllGameData, let transfers else { return }
        let wanted = Set(titleIDs.map { $0.uppercased() })
        let chosen = sharedAppDataSources().filter { wanted.contains($0.titleID.uppercased()) }
        guard !chosen.isEmpty else { return }
        let device = devices.installDevice, name = devices.deviceName(device)
        transfers.enqueue(chosen.map {
            TransferEntry(titleID: $0.titleID, name: $0.name, archive: $0.archive, deviceID: device, deviceName: name)
        })
    }

    /// The transfer queue's way to send one entry. It runs beside a build: it touches neither `running` nor the stages.
    package func performTransfer(_ entry: TransferEntry, report: @escaping @MainActor (Int64, Int64) -> Void,
                                 finish: @escaping @MainActor (TransferResult) -> Void) {
        var installer = makeInstaller()
        installer.device = entry.deviceID
        installer.deviceName = entry.deviceName
        installer.stage = { _ in }
        let cancelled = LockedFlag()
        transferCancels[entry.id] = cancelled
        installer.waitCancelled = { cancelled.value }
        installer.decideCopy = { plan in plan.connection == .notConnected ? .skip : .copy }
        installer.copyProgress = { done, total in hop { report(done, total) } }
        let ready = installer
        DispatchQueue.global(qos: .utility).async {
            let result = ready.sendData(titleID: entry.titleID, archive: entry.archive, bundleID: entry.bundleID)
            hop {
                self.transferCancels[entry.id] = nil
                if result.ok { finish(.done); return }
                Task { @MainActor in
                    await self.devices.refreshDevices()
                    finish(Self.transferResult(of: result, deviceConnected: ShellInstall.connection(of: entry.deviceID, in: self.devices.devices) != .notConnected))
                }
            }
        }
    }

    /// Asks the running send of an entry to stop.
    package func cancelTransfer(_ id: UUID) { transferCancels[id]?.set(true) }

    /// What a send's outcome means for the queue. A device that is not connected is waiting, whether the send never started or the device
    /// went away in the middle: the parts that are on the device stay, and the next try checks them.
    static func transferResult(of outcome: ShellInstaller.Outcome, deviceConnected: Bool) -> TransferResult {
        if outcome.ok { return .done }
        if outcome.copySkipped || !deviceConnected { return .deviceAbsent }
        return .failed(outcome.message)
    }

    /// Finder recovery of a failed transfer: its own game's data folder, never the selected game's.
    package func revealTransfer(_ entry: TransferEntry) {
        guard entry.status == .failed else { return }
        revealItem(URL(fileURLWithPath: entry.archive))
    }
}
