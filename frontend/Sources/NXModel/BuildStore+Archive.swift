import Foundation
import Combine
import NXCore

// The archive step after the script: the RomFS image the game data goes over with (LNPANDY/NX2Apple#387).

extension BuildStore {
    // MARK: Archive

    nonisolated static func placeAddOnContentOnBackground(workDir: String, in dest: String) -> Int {
        let count = PostBuildCleanup.placeAddOnContent(from: workDir + "/aoc", to: dest + "/aoc")
        if let fw = ShellInstall.builtFramework(workDir: workDir) {
            RomFSLanguages.applyToLauncherJSON(at: fw + "/dm/launcher.json", romfs: dest)
        }
        return count
    }

    /// The DLC images ride along: with the slim default the build script leaves them in the work folder
    /// instead of packing them into the IPA, and the host mounts them from DM_AOC_DIR/<index>.img, so
    /// they belong in this game's folder. Every way the archive step can end (folder pack, image move,
    /// image reuse, stamp reuse) goes through here (issue #202).
    package func placeAddOnContent(workDir: String, in dest: String) {
        let n = Self.placeAddOnContentOnBackground(workDir: workDir, in: dest)
        if n > 0 { say(String(format: t("msg.aocCopied"), n)) }
    }

    /// Pack or move the extracted RomFS into one `romfs.img` off the main actor, then reclaim intermediate build files in `workDir`.
    /// `then` continues the build with the archive's folder (installing on a device or exporting the shared app).
    /// `titleID` names the folder (the framework's title ID), falling back to the build key when omitted.
    package func packArchive(workDir: String, titleID: String? = nil, then: @escaping (String) -> Void) {
        buildingGame = true; runningTarget = BuildTarget.ios
        if operation == nil { beginOperation(.building, game: gameName, titleID: titleID, destination: .target) }
        running = true
        archiveGeneration &+= 1
        let generation = archiveGeneration
        let gamesRoot = (outDir.isEmpty ? inputFolder : outDir) + "/games"
        let tid = titleID.flatMap { $0.isEmpty ? nil : $0 } ?? buildKey
        let dest = gamesRoot + "/" + tid
        let repoPath = repo.path
        let pythonPath = deps.pythonPath
        let idx = 1000

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            let extract = workDir + "/extract"
            guard let v = RomFSArchive.extractedVersion(in: extract) else {
                hop {
                    guard let self, self.archiveGeneration == generation else { return }
                    self.stages.append(Stage(id: idx, name: self.t("prog.archiveShort"), state: .failed, detail: self.t("prog.noRomfs")))
                    self.doneNote = String(format: self.t("msg.archiveSkipped"), extract)
                    self.running = false
                    self.cleanupStaging()
                }
                return
            }

            let romfs = extract + "/" + v + "/RomFS"
            let romfsImage = extract + "/" + v + "/RomFS.img"
            try? fm.createDirectory(atPath: dest, withIntermediateDirectories: true)

            let stampPath = dest + "/.packstamp"
            if let stamp = try? String(contentsOfFile: stampPath, encoding: .utf8), !stamp.isEmpty,
               let reused = RomFSArchive.archiveReusable(source: romfs, version: v, stamp: stamp) {
                let aocCount = Self.placeAddOnContentOnBackground(workDir: workDir, in: dest)
                PostBuildCleanup.cleanWorkDirectory(workDir, removeExtractedRomFS: false, removeShellFramework: false)
                hop {
                    guard let self, self.archiveGeneration == generation else { return }
                    if self.stopping {
                        self.finishStoppedArchive()
                        return
                    }
                    self.archivePath = dest
                    self.stages.append(Stage(id: idx, name: self.t("prog.archive"), state: .done,
                                             detail: String(format: self.t("prog.archiveReused"), reused)))
                    self.say(String(format: self.t("msg.archiveReused"), dest))
                    if aocCount > 0 { self.say(String(format: self.t("msg.aocCopied"), aocCount)) }
                    then(dest)
                }
                return
            }

            // Remove legacy ROMFSARC shards while keeping any existing romfs.img in place until PostBuildCleanup.placeImage
            // either matches its size and modification date or replaces it atomically.
            for old in ((try? fm.contentsOfDirectory(atPath: dest)) ?? [])
            where old == "romfs.idx" || (old.hasPrefix("romfs.") && old.dropFirst(6).allSatisfy(\.isNumber)) {
                try? fm.removeItem(atPath: dest + "/" + old)
            }

            if fm.fileExists(atPath: romfsImage) {
                hop {
                    guard let self, self.archiveGeneration == generation, !self.stopping else { return }
                    self.upsertArchiveStage(id: idx, state: .running, detail: v)
                    self.say(String(format: self.t("msg.archiveLog"), romfs, dest))
                }
                do {
                    let placement = try PostBuildCleanup.placeImage(from: romfsImage, to: dest + "/romfs.img")
                    let aocCount = Self.placeAddOnContentOnBackground(workDir: workDir, in: dest)
                    PostBuildCleanup.cleanWorkDirectory(workDir, removeExtractedRomFS: true, removeShellFramework: false)
                    hop {
                        guard let self, self.archiveGeneration == generation else { return }
                        if self.stopping {
                            self.finishStoppedArchive()
                            return
                        }
                        switch placement {
                        case .reused:
                            self.upsertArchiveStage(id: idx, state: .done, detail: String(format: self.t("prog.archiveReused"), 1))
                            self.say(String(format: self.t("msg.archiveReused"), dest))
                        case .moved:
                            self.upsertArchiveStage(id: idx, state: .done, detail: v)
                            self.say(String(format: self.t("msg.archiveLog"), romfsImage, dest))
                        }
                        if aocCount > 0 { self.say(String(format: self.t("msg.aocCopied"), aocCount)) }
                        self.archivePath = dest
                        then(dest)
                    }
                } catch {
                    hop {
                        guard let self, self.archiveGeneration == generation else { return }
                        self.upsertArchiveStage(id: idx, state: .failed, detail: error.localizedDescription)
                        self.doneNote = String(format: self.t("msg.archiveFailed"), 1)
                        self.running = false
                        self.cleanupStaging()
                    }
                }
                return
            }

            for old in ["romfs.img", "romfs.img.id"] {
                try? fm.removeItem(atPath: dest + "/" + old)
            }
            hop {
                guard let self, self.archiveGeneration == generation else { return }
                if self.stopping {
                    self.finishStoppedArchive()
                    return
                }
                self.upsertArchiveStage(id: idx, state: .running, detail: v)
                self.say(String(format: self.t("msg.archiveLog"), romfs, dest))
                self.launchLegacyRomFSImagePack(workDir: workDir, romfs: romfs, version: v, dest: dest,
                                                repoPath: repoPath, pythonPath: pythonPath, stageID: idx,
                                                generation: generation, then: then)
            }
        }
    }

    private func upsertArchiveStage(id: Int, state: StepState, detail: String) {
        if let i = stages.firstIndex(where: { $0.id == id }) {
            stages[i].state = state
            stages[i].detail = detail
        } else {
            stages.append(Stage(id: id, name: t("prog.archive"), state: state, detail: detail))
        }
    }

    private func finishStoppedArchive() {
        stopping = false
        running = false
        done = false
        resetProgress()
        doneNote = t("msg.stopped")
        cleanupStaging()
    }

    private func launchLegacyRomFSImagePack(workDir: String, romfs: String, version: String, dest: String,
                                            repoPath: String, pythonPath: String, stageID: Int,
                                            generation: Int, then: @escaping (String) -> Void) {
        let engine = EngineLayout.root(repoPath)
        let romfsPy = pythonPath.isEmpty ? "/usr/bin/python3" : pythonPath
        let launch = ProcessLaunch(
            executable: romfsPy,
            arguments: [engine + "/" + RepoLayout.romfsImageTool, "--reuse", romfs, dest + "/romfs.img"],
            environment: ["PATH": BuildCommands.toolPath("/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin", python: romfsPy),
                          "PYTHONPATH": engine + "/dm/tools"]
                .merging(BundledTools.environment(for: romfsPy)) { $1 },
            groupPython: romfsPy
        )
        let onExit: @Sendable (Int32) -> Void = { [weak self] st in
            hop {
                guard let self, self.archiveGeneration == generation else { return }
                let cancelled = self.stopping
                let succeeded = st == 0 && !cancelled
                self.stopping = false
                guard succeeded else {
                    self.upsertArchiveStage(id: stageID, state: .failed, detail: String(format: self.t("msg.archiveFailed"), st))
                    self.cleanupStaging()
                    self.running = false
                    self.done = false
                    if cancelled { self.resetProgress() }
                    self.doneNote = cancelled ? self.t("msg.stopped") : String(format: self.t("msg.archiveFailed"), st)
                    return
                }
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    RomFSArchive.writeStamp(source: romfs, version: version, to: dest + "/.packstamp")
                    let aocCount = Self.placeAddOnContentOnBackground(workDir: workDir, in: dest)
                    PostBuildCleanup.cleanWorkDirectory(workDir, removeExtractedRomFS: true, removeShellFramework: false)
                    hop {
                        guard let self, self.archiveGeneration == generation else { return }
                        if self.stopping {
                            self.finishStoppedArchive()
                            return
                        }
                        self.archivePath = dest
                        if aocCount > 0 { self.say(String(format: self.t("msg.aocCopied"), aocCount)) }
                        self.upsertArchiveStage(id: stageID, state: .done, detail: String(format: self.t("prog.archiveDone"), dest))
                        then(dest)
                    }
                }
            }
        }
        do {
            proc = try runner.start(launch, onOutput: { @Sendable [weak self] d in
                guard let s = String(data: d, encoding: .utf8) else { return }
                hop { self?.append(s) }
            }, onExit: onExit)
        } catch {
            upsertArchiveStage(id: stageID, state: .failed, detail: t("msg.archiveNoStart"))
            running = false
            doneNote = t("msg.archiveNoStart")
            cleanupStaging()
        }
    }
}
