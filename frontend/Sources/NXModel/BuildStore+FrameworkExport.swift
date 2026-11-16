import Foundation
@preconcurrency import NXCore

// Standalone `.framework` export for the shared app: copies the built `DmGame<TitleID>.framework` to the output folder,
// places its banner, optionally signs with a local team identity when available, and skips building or repacking the shell IPA.

extension BuildStore {
    package func exportFrameworkBundle(framework: String, titleID: String, name: String) {
        buildingGame = true
        runningTarget = BuildTarget.ios
        beginOperation(.exportingIPA, game: name, titleID: titleID, destination: .none)
        running = true

        let workDir = effectiveWorkDir
        let outFolder = effectiveOutputFolder.isEmpty
            ? (workDir as NSString).deletingLastPathComponent
            : effectiveOutputFolder
        let tid = (titleID.isEmpty ? ShellInstall.titleID(ofFramework: framework) : titleID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let team = devices.signingTeam
        let runner = self.runner
        let picked = pickedArtworkForTitleID(tid)
        let banners = BannerCache.directory
        archiveGeneration &+= 1
        let generation = archiveGeneration

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = Self.stageAndReplaceFramework(
                framework: framework,
                titleID: tid,
                outFolder: outFolder,
                team: team,
                runner: runner,
                banners: banners,
                pickedBanner: picked,
                workDir: workDir
            )
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
                guard let destPath = outcome.destPath else {
                    let msg = String(format: self.t("shell.exportFailed"), outcome.error ?? "unknown error")
                    self.finishInstall(msg)
                    return
                }
                self.exportedIPAPath = destPath
                self.finishInstall(nil, note: String(format: self.t("shell.frameworkExportDone"), destPath))
            }
        }
    }

    nonisolated private static func stageAndReplaceFramework(
        framework: String,
        titleID: String,
        outFolder: String,
        team: String,
        runner: ProcessRunner,
        banners: URL,
        pickedBanner: String?,
        workDir: String
    ) -> (destPath: String?, error: String?) {
        let fm = FileManager.default
        guard !framework.isEmpty, fm.fileExists(atPath: framework) else {
            return (nil, "missing built framework at \(framework)")
        }
        guard !outFolder.isEmpty else {
            return (nil, "missing output folder")
        }

        let fwName = titleID.isEmpty
            ? URL(fileURLWithPath: framework).deletingPathExtension().lastPathComponent
            : "DmGame\(titleID)"
        let outURL = URL(fileURLWithPath: outFolder, isDirectory: true)
        let token = UUID().uuidString
        let tmpURL = outURL.appendingPathComponent(".\(fwName).framework.tmp-\(token)", isDirectory: true)
        let oldURL = outURL.appendingPathComponent(".\(fwName).framework.old-\(token)", isDirectory: true)
        let destURL = outURL.appendingPathComponent("\(fwName).framework", isDirectory: true)

        do {
            try fm.createDirectory(at: outURL, withIntermediateDirectories: true)
            try fm.copyItem(at: URL(fileURLWithPath: framework, isDirectory: true), to: tmpURL)
            _ = ShellInstall.placeBanner(titleID: titleID, framework: tmpURL.path, banners: banners, picked: pickedBanner, fm: fm)

            let plistURL = tmpURL.appendingPathComponent("Info.plist")
            guard fm.fileExists(atPath: plistURL.path),
                  let plistData = try? Data(contentsOf: plistURL),
                  let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
                try? fm.removeItem(at: tmpURL)
                return (nil, "missing or unreadable Info.plist in \(fwName).framework")
            }
            let exeName = (plist["CFBundleExecutable"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fwName
            guard fm.fileExists(atPath: tmpURL.appendingPathComponent(exeName).path) else {
                try? fm.removeItem(at: tmpURL)
                return (nil, "missing executable \(exeName) in \(fwName).framework")
            }

            if !team.isEmpty, let identity = ShellHotInstall.defaultSigningIdentity(team: team, runner: runner) {
                let xattrCmd = ShellHotInstall.cleanFrameworkAttributesCommand(framework: tmpURL.path)
                _ = runner.capture(ProcessLaunch(executable: xattrCmd[0], arguments: Array(xattrCmd.dropFirst()), environment: [:]))
                let signCmd = ShellHotInstall.codesignFrameworkCommand(identity: identity, framework: tmpURL.path)
                let signResult = runner.capture(ProcessLaunch(executable: signCmd[0], arguments: Array(signCmd.dropFirst()), environment: [:]))
                if !signResult.ok {
                    try? fm.removeItem(at: tmpURL)
                    let detail = (signResult.err.isEmpty ? signResult.out : signResult.err).trimmingCharacters(in: .whitespacesAndNewlines)
                    return (nil, detail.isEmpty ? "codesign failed (\(signResult.status))" : detail)
                }
            }

            let hasExisting = fm.fileExists(atPath: destURL.path) || (try? fm.attributesOfItem(atPath: destURL.path)) != nil
            if hasExisting {
                try fm.moveItem(at: destURL, to: oldURL)
            }
            var replaced = false
            do {
                try fm.moveItem(at: tmpURL, to: destURL)
                replaced = true
            } catch {
                // Always clear any partial/dangling destination before restoring the previous backup.
                try? fm.removeItem(at: destURL)
                if fm.fileExists(atPath: oldURL.path) {
                    try? fm.moveItem(at: oldURL, to: destURL)
                }
                throw error
            }
            if replaced && fm.fileExists(atPath: oldURL.path) {
                try? fm.removeItem(at: oldURL)
            }
            PostBuildCleanup.cleanWorkDirectory(workDir, removeExtractedRomFS: false, removeShellFramework: true)
            return (destURL.path, nil)
        } catch {
            try? fm.removeItem(at: tmpURL)
            return (nil, error.localizedDescription)
        }
    }
}
