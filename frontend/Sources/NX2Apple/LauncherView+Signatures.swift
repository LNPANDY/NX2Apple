import AppKit
import SwiftUI
@preconcurrency import NXCore
import NXModel

/// Reads and tracks installed apps' provisioning-profile expiration dates off the main thread, dropping results from older generations
/// when the library changes, empties or finishes a re-sign before an earlier `security cms` check returns.
@MainActor final class SignatureTracker: ObservableObject {
    @Published private(set) var expiry: [UUID: Date] = [:]
    private(set) var generation = 0

    func refresh(games: [LibraryGame], runner: ProcessRunner) {
        let apps = games.filter(\.onDevice).map { ($0.id, $0.iosAppPath) }
        refresh(apps: apps, runner: runner)
    }

    func refresh(apps: [(UUID, String)], runner: ProcessRunner) {
        generation &+= 1
        let expected = generation
        guard !apps.isEmpty else {
            expiry = [:]
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = AppSignature.expirations(ofApps: apps, runner: runner)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == expected else { return }
                    self.expiry = found
                }
            }
        }
    }
}

extension LauncherView {
    /// The installed apps' profile expiries, read in the background: `security cms` per unique app path, so not in a view body.
    func readSignatures() {
        signatures.refresh(games: library.games, runner: stores.runner)
    }

    /// Sign the installed app again for another 7 days (a free Apple ID's profile), then install it: the game's code
    /// is not rebuilt, and its Documents stay.
    func resign(_ game: LibraryGame) {
        resignNote = nil
        m.resignOnDevice(app: game.iosAppPath, device: game.installedDevice) {
            resignNote = m.doneNote
            if !m.installedOn.isEmpty { library.recordSharedAppInstalled(app: m.installedAppPath, device: m.installedOn) }
            readSignatures()
        }
    }

    func chooseLibraryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = loc.t("library.folderHint")
        if !library.folder.isEmpty { panel.directoryURL = URL(fileURLWithPath: library.folder) }
        if panel.runModal() == .OK, let url = panel.url {
            let first = library.folders.isEmpty
            library.addFolder(url)   // several folders are allowed (#992)
            if first, !m.running { m.outDir = url.path }   // where a build goes stays the player's explicit choice
        }
    }
}
