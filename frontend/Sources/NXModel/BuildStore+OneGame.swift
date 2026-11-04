import Foundation
import NXCore

// One game's own IPA with its game data inside (LNPANDY/NX2Apple#540). The build script makes it whole, so after the script there is
// no archive step, no shared app and nothing to send: the IPA is step 1 of the export card, and step 2 installs it with another tool.

extension BuildStore {
    /// The script ended well: the IPA is the export's result, or the build says that it is missing.
    func finishOneGameIPA() {
        let ipa = oneGameIPAPath
        let made = FileManager.default.fileExists(atPath: ipa)
        exportedIPAPath = made ? ipa : ""
        done = made
        doneNote = String(format: t(made ? "shell.exportDone" : "shell.oneGameMissing"), ipa)
        running = false
        cleanupStaging()
    }
}
