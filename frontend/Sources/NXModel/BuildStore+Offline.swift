import Foundation
import NXCore

extension BuildStore {
    func finishOfflineApp() {
        running = true; done = false; preparingOffline = true; offlineCancelled.set(false)
        doneNote = t("offline.preparing")
        let app = URL(fileURLWithPath: macAppPath)
        let save = offlineSaveFolder.isEmpty ? nil : URL(fileURLWithPath: offlineSaveFolder)
        let caches = offlineCacheFolder.isEmpty ? nil : URL(fileURLWithPath: offlineCacheFolder)
        let cancellation = offlineCancelled
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failure: String?
            do {
                let candidate = try OfflineAppSeed.prepareCopy(app: app, save: save, caches: caches, cancelled: { cancellation.value }) { stagedApp in
                    for arguments in [["--force", "--deep", "--sign", "-", stagedApp.path], ["--verify", "--deep", "--strict", stagedApp.path]] {
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                        process.arguments = arguments
                        try process.run(); process.waitUntilExit()
                        if process.terminationStatus != 0 { throw CocoaError(.fileWriteUnknown) }
                    }
                }
                try OfflineAppSeed.publish(candidate: candidate, over: app)
            } catch { failure = error.localizedDescription }
            let result = failure
            hop {
                guard let self else { return }
                self.preparingOffline = false; self.running = false; self.stopping = false
                self.done = result == nil
                self.doneNote = result.map { self.t("offline.failed") + $0 } ?? self.t("msg.macAppDone")
                self.cleanupStaging()
            }
        }
    }
}
