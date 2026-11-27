import Foundation
import NXCore

// One game's own IPA with its game data inside (LNPANDY/NX2Apple#540). The build script makes it whole, so after the script there is
// no archive step, no shared app and nothing to send: the IPA is step 1 of the export card, and step 2 installs it with another tool.

@MainActor private final class KWSSeparateProbeTracker {
    var generation: UInt64 = 0
}

@MainActor private let kwsProbeTrackers = NSMapTable<BuildStore, KWSSeparateProbeTracker>.weakToStrongObjects()

extension BuildStore {
    private var kwsProbeTracker: KWSSeparateProbeTracker {
        if let existing = kwsProbeTrackers.object(forKey: self) { return existing }
        let created = KWSSeparateProbeTracker()
        kwsProbeTrackers.setObject(created, forKey: self)
        return created
    }

    /// True when the active engine and target expose the external `romfs.img` option (`--romfs separate`).
    package var supportsSeparateRomfsOption: Bool {
        buildUpstream == .kidWithSword && target != BuildTarget.mac
    }

    /// True when the active standalone Kid with Sword iOS build is configured to leave `romfs.img` out of the IPA.
    package var usesSeparateRomfsForCurrentBuild: Bool {
        target != BuildTarget.mac
            && buildUpstream == .kidWithSword
            && exportsOneGame
            && (queuedSeparateRomfs ?? kwsSeparateRomfs)
    }

    /// Refreshes whether the installed Kid with Sword tree accepts `--romfs` off the main actor.
    package func refreshKWSSeparateRomfsSupport() {
        let tracker = kwsProbeTracker
        tracker.generation &+= 1
        let gen = tracker.generation
        let tree = kidWithSwordPath
        guard !tree.isEmpty, UpstreamEngineStore.isUsableTree(tree, kind: .kidWithSword) else {
            if !kwsSupportsSeparateRomfs { kwsSupportsSeparateRomfs = true }
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let supported = RepoLayout.supportsRomfsMode(tree)
            hop {
                guard let self,
                      self.kwsProbeTracker.generation == gen,
                      self.kidWithSwordPath == tree else {
                    return
                }
                if self.kwsSupportsSeparateRomfs != supported {
                    self.kwsSupportsSeparateRomfs = supported
                }
            }
        }
    }

    /// Clears separate-RomFS completion state before starting, failing, or running another delivery mode.
    package func clearSeparateRomfsState(includeActiveBuild: Bool = true) {
        externalRomfsImagePath = ""
        completedOneGameSeparateRomfs = false
        if includeActiveBuild {
            activeSeparateRomfsBuild = false
        }
    }

    /// The script ended well: the IPA is the export's result, or the build says that it is missing.
    func finishOneGameIPA() {
        running = true
        let ipa = oneGameIPAPath
        let workDir = effectiveWorkDir
        let separate = activeSeparateRomfsBuild
        archiveGeneration &+= 1
        let generation = archiveGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let made = FileManager.default.fileExists(atPath: ipa)
            var stagedRomfs = ""
            if made {
                if separate {
                    PostBuildCleanup.cleanWorkDirectory(workDir, removeExtractedRomFS: false, removeShellFramework: true)
                    stagedRomfs = OneGameIPA.stageSeparateRomFSImage(workDir: workDir, ipaPath: ipa) ?? ""
                } else {
                    PostBuildCleanup.cleanWorkDirectory(workDir, removeExtractedRomFS: true, removeShellFramework: true)
                    OneGameIPA.cleanupSeparateRomFSArtifacts(forIPA: ipa)
                }
            }
            hop {
                guard let self, self.archiveGeneration == generation else { return }
                if self.stopping {
                    self.stopping = false
                    self.running = false
                    self.activeSeparateRomfsBuild = false
                    self.resetProgress()
                    self.doneNote = self.t("msg.stopped")
                    self.cleanupStaging()
                    return
                }
                self.exportedIPAPath = made ? ipa : ""
                self.externalRomfsImagePath = (made && separate) ? stagedRomfs : ""
                self.completedOneGameSeparateRomfs = made && separate
                self.activeSeparateRomfsBuild = false
                self.done = made
                if made { self.completeOverallProgress() }
                if made && separate {
                    self.doneNote = String(format: self.t("shell.exportSeparateDone"), ipa)
                } else {
                    self.doneNote = String(format: self.t(made ? "shell.exportDone" : "shell.oneGameMissing"), ipa)
                }
                self.running = false
                self.cleanupStaging()
            }
        }
    }
}
