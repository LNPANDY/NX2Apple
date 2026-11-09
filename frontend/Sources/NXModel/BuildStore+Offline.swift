import Foundation
import NXCore

extension BuildStore {
    func finishOfflineApp() {
        running = true; done = false; preparingOffline = true; offlineCancelled.set(false); offlineProcess.reset()
        doneNote = t("offline.preparing")
        let app = URL(fileURLWithPath: macAppPath)
        let save = offlineSaveFolder.isEmpty ? nil : URL(fileURLWithPath: offlineSaveFolder)
        let caches = offlineCacheFolder.isEmpty ? nil : URL(fileURLWithPath: offlineCacheFolder)
        let cancellation = offlineCancelled
        let processRunner = runner
        let control = offlineProcess
        let python = deps.pythonPath.isEmpty ? Toolchain.findPython().path : deps.pythonPath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failure: Error?
            do {
                let details = processRunner.capture(ProcessLaunch(executable: "/usr/bin/codesign", arguments: ["--display", "--verbose=4", app.path]))
                guard details.ok else { throw CocoaError(.fileReadCorruptFile) }
                let identity = try OfflineSigning.identity(from: details.out + "\n" + details.err)
                let candidate = try OfflineAppSeed.prepareCopy(app: app, save: save, caches: caches, cancelled: { cancellation.value }) { stagedApp in
                    for arguments in [["--force", "--deep", "--sign", identity, "--preserve-metadata=entitlements,requirements,flags,runtime", stagedApp.path], ["--verify", "--deep", "--strict", stagedApp.path]] {
                        if cancellation.value { throw CancellationError() }
                        let result = processRunner.streamLines(ProcessLaunch(executable: "/usr/bin/codesign", arguments: arguments, groupPython: python), started: { control.started($0.processIdentifier) }, line: { _ in })
                        control.ended()
                        if cancellation.value { throw CancellationError() }
                        if !result.ok { throw CocoaError(.fileWriteUnknown) }
                    }
                }
                try OfflineAppSeed.publish(candidate: candidate, over: app)
            } catch { failure = error }
            let result = failure
            hop {
                guard let self else { return }
                self.preparingOffline = false; self.running = false; self.stopping = false
                self.done = result == nil
                if result is CancellationError {
                    self.doneNote = self.t("msg.stopped")
                } else {
                    self.doneNote = result.map { self.t("offline.failed") + (($0 as? OfflineDataInventory.ValidationError)?.message(self.t) ?? $0.localizedDescription) } ?? self.t("msg.macAppDone")
                }
                self.cleanupStaging()
            }
        }
    }
}
