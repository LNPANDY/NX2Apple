import Foundation
import NXCore

// One game's own IPA with its game data inside (LNPANDY/NX2Apple#540). The build script makes it whole, so after the script there is
// no archive step, no shared app and nothing to send: the IPA is step 1 of the export card, and step 2 installs it with another tool.

extension BuildStore {
    /// The script ended well: the IPA is the export's result, or the build says that it is missing.
    func finishOneGameIPA() {
        running = true
        let ipa = oneGameIPAPath
        let workDir = effectiveWorkDir
        archiveGeneration &+= 1
        let generation = archiveGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let made = FileManager.default.fileExists(atPath: ipa)
            if made {
                PostBuildCleanup.cleanWorkDirectory(workDir, removeExtractedRomFS: true, removeShellFramework: true)
            }
            hop {
                guard let self, self.archiveGeneration == generation else { return }
                if self.stopping {
                    self.stopping = false
                    self.running = false
                    self.resetProgress()
                    self.doneNote = self.t("msg.stopped")
                    self.cleanupStaging()
                    return
                }
                self.exportedIPAPath = made ? ipa : ""
                self.done = made
                self.doneNote = String(format: self.t(made ? "shell.exportDone" : "shell.oneGameMissing"), ipa)
                self.running = false
                self.cleanupStaging()
            }
        }
    }
}
