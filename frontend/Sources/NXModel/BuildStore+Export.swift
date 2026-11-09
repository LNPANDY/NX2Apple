import Foundation
import Combine
import NXCore

// The shared app as an unsigned IPA (LNPANDY/NX2Apple#416). The steps are ShellInstaller.export (NXCore, ShellExport.swift): this
// runs them off the main actor and shows what they leave. No device, no signing team, no game data copy.

extension BuildStore {
    /// Makes the IPA for a game whose framework is built: the shell's project with the frameworks of the games in its library, built
    /// unsigned, zipped as Payload/<app>.app. The game's data stays where the archive step put it.
    package func exportShell(framework: String, titleID: String, name: String, archive: String = "") {
        buildingGame = true; runningTarget = BuildTarget.ios
        runExport { $0.export(framework: framework, titleID: titleID, name: name, archive: archive) }
    }

    /// Makes the IPA again from the games built before, without building one: "Export these games" under step 1. The stale prompt
    /// asks first when a framework of the library belongs to another shader chain, and Continue comes back here.
    package func exportLibrary() {
        guard !running, exportsShell, !exportsOneGame else { return }
        if askAboutStaleFrameworks(except: nil, resume: { [weak self] in self?.exportLibrary() }) { return }
        stopping = false
        done = false; doneNote = ""; stages = []; failure = nil; confirmingOverride = nil
        log.clear()
        installedOn = ""; installedAppPath = ""; exportedIPAPath = ""; send = .idle
        if let why = shellRootProblem() { fail(why); return }
        buildingGame = false; runningTarget = BuildTarget.ios   // no game is built: the export alone runs
        runExport { $0.exportLibrary() }
    }

    /// The games of the shared app that an export without a build would put in the IPA: those whose framework is still there. Read
    /// from the shell folder the launcher would use, without moving or creating it (`shellCachePath`). Each game's `archive` is its
    /// data folder as found now (the recorded one, else where the library says the game was built), nil when none holds the data.
    package func refreshShellGames() {
        let fm = FileManager.default
        shellGames = ShellLibrary.load(root: shellCachePath).games.filter { fm.fileExists(atPath: $0.framework) }.map { game in
            var found = game
            let candidates = ShellGameData.candidates(titleID: game.titleID, recorded: [game.archive ?? ""] + gameDataCandidates(game.titleID), parents: [])
            found.archive = ShellGameData.folder(in: candidates, fm: fm)
            return found
        }
        refreshDrive()
    }

    private func runExport(_ export: @escaping @Sendable (ShellInstaller) -> ShellInstaller.Outcome) {
        running = true
        let installer = makeInstaller()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = export(installer)
            hop {
                self.refreshShellGames()
                if self.stopping {
                    self.stopping = false; self.running = false
                    self.resetProgress(); self.doneNote = self.t("msg.stopped"); self.cleanupStaging()
                    return
                }
                guard result.ok else { self.finishInstall(result.message); return }
                self.exportedIPAPath = result.ipaPath
                self.finishInstall(nil, note: result.message)
            }
        }
    }
}
