import Foundation
import Combine
import NXCore

// The shared app as an unsigned IPA (LNPANDY/NX2Apple#416). The steps are ShellInstaller.export (NXCore, ShellExport.swift): this
// runs them off the main actor and shows what they leave. No device, no signing team, no game data copy.

extension BuildStore {
    /// Makes the IPA for a game whose framework is built: the shell's project with the frameworks of the games in its library, built
    /// unsigned, zipped as Payload/<app>.app. The game's data stays where the archive step put it.
    package func exportShell(framework: String, titleID: String, name: String, extraFrameworksToClean: [String] = []) {
        buildingGame = true; runningTarget = BuildTarget.ios
        beginOperation(.exportingIPA, game: name, titleID: titleID, destination: .none)
        running = true
        let installer = makeInstaller()
        let root = installer.root
        DispatchQueue.global(qos: .userInitiated).async {
            let result = installer.export(framework: framework, titleID: titleID, name: name)
            if result.ok {
                PostBuildCleanup.cleanShellExportProducts(root: root)
                let surviving = Set(ShellLibrary.load(root: root).games.map { $0.titleID.uppercased() })
                for fw in ([framework] + extraFrameworksToClean) {
                    let tid = ShellInstall.titleID(ofFramework: fw).uppercased()
                    if !tid.isEmpty, surviving.contains(tid) {
                        PostBuildCleanup.cleanBuiltFrameworkContainer(fw)
                    }
                }
            }
            hop {
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
