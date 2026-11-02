import Foundation
import Combine
import NXCore

// The archive step after the script: the RomFS image the game data goes over with (LNPANDY/NX2Apple#387).

extension BuildStore {
    // MARK: Archive

    /// The DLC images ride along: with the slim default the build script leaves them in the work folder
    /// instead of packing them into the IPA, and the host mounts them from DM_AOC_DIR/<index>.img, so
    /// they belong in this game's folder. Every way the archive step can end (folder pack, image copy,
    /// image reuse, stamp reuse) goes through here (issue #202).
    package func placeAddOnContent(workDir: String, in dest: String) {
        let n = RomFSArchive.copyAddOnContent(from: workDir + "/aoc", to: dest + "/aoc")
        if n > 0 { say(String(format: t("msg.aocCopied"), n)) }
    }

    /// Pack the extracted RomFS into one romfs.img. The extracted folder is
    /// <work>/extract/v<N>/RomFS where N is the profile's package version, so take
    /// the highest v* that actually has a RomFS instead of hardcoding one game.
    /// `then` continues the build with the archive's folder (installing on a device).
    package func packArchive(workDir: String, then: @escaping (String) -> Void) {
        running = true
        let fm = FileManager.default
        let extract = workDir + "/extract"
        // The extraction writes either a RomFS folder (older tools) or RomFS.img, one image file
        // (the rewriter packs it now: build_ipa_from_nsp.py:876 tests for exactly that). Looking
        // only for the folder made every 0.4.8 build end with "archive skipped" on a machine where
        // the extraction had in fact succeeded (issue #73). extractedVersion is the one authority:
        // an inline copy of its predicate here drifted back to folder-only during a merge, and the
        // archive skipped again while the test — which drives the function — stayed green.
        guard let v = RomFSArchive.extractedVersion(in: extract) else {
            stages.append(Stage(id: 1000, name: t("prog.archiveShort"), state: .failed, detail: t("prog.noRomfs")))
            doneNote = String(format: t("msg.archiveSkipped"), extract)
            running = false; cleanupStaging(); return
        }
        let romfs = extract + "/" + v + "/RomFS"
        let romfsImage = extract + "/" + v + "/RomFS.img"
        // The output is Documents/games/<title ID>/romfs — the per-game layout the iOS app looks for
        // first. Copying the whole `games` folder onto the phone (or into a folder the Files app
        // exposes on an external drive) then needs no renaming, and several games' folders can sit
        // side by side in one app.
        let gamesRoot = (outDir.isEmpty ? (basePath as NSString).deletingLastPathComponent : outDir) + "/games"
        let tid = TitleID.buildKey(basePath)
        // games/<id>/ holds romfs.img and aoc/ side by side: main.m's per-game lookup takes the
        // image, and the host mounts DLC from aoc/<index>.img (hle_fs.c aoc_dir). One folder, which
        // the user copies to the phone or keeps on an external drive as a whole.
        let gameDir = gamesRoot + "/" + tid
        let dest = gameDir
        try? fm.createDirectory(atPath: dest, withIntermediateDirectories: true)
        // Reuse: packing is a multi-GB write, and the extracted RomFS is itself reused by the
        // script — so when the source tree's (version, file count, bytes) matches the stamp left
        // in the folder, the shards are already correct and the pack is skipped. A different
        // version changes the extract; a same-version re-extract of the same NSPs reproduces the
        // same tree.
        let stampPath = dest + "/.packstamp"
        if let stamp = try? String(contentsOfFile: stampPath, encoding: .utf8), !stamp.isEmpty,
           let reused = RomFSArchive.archiveReusable(source: romfs, version: v, stamp: stamp) {
            archivePath = dest
            stages.append(Stage(id: 1000, name: t("prog.archive"), state: .done,
                                detail: String(format: t("prog.archiveReused"), reused)))
            say(String(format: t("msg.archiveReused"), dest))
            placeAddOnContent(workDir: workDir, in: dest)
            return then(dest)
        }
        // One romfs.img instead of a ROMFSARC shard set: upstream reads the image directly
        // (hle_fs.c), one file copies to a phone at full speed where 300,000 did not, and it fits
        // an external drive. A shard set from an earlier build of this game is removed first —
        // main.m takes Documents/games/<id>/romfs.img before romfs/, so a stale archive would sit
        // there confusingly.
        for old in ((try? fm.contentsOfDirectory(atPath: dest)) ?? [])
        where old == "romfs.img" || old == "romfs.idx" || (old.hasPrefix("romfs.") && old.dropFirst(6).allSatisfy(\.isNumber)) {
            try? fm.removeItem(atPath: dest + "/" + old)
        }
        let idx = 1000
        stages.append(Stage(id: idx, name: t("prog.archive"), state: .running, detail: v))
        say(String(format: t("msg.archiveLog"), romfs, dest))

        // The extraction may already have packed the image (RomFS.img beside the code modules): then
        // this is a copy, not a pack. Packing it again from a folder that no longer exists was the
        // other half of issue #73.
        if fm.fileExists(atPath: romfsImage) {
            let to = dest + "/romfs.img"
            // Reuse by the image's own identity: copying a multi-GB file on every build of an
            // unchanged game is the cost this avoids. Size and modification date are enough — the
            // extraction rewrites the file whenever the game's data changes.
            if let src = try? fm.attributesOfItem(atPath: romfsImage),
               let have = try? fm.attributesOfItem(atPath: to),
               let a = src[.size] as? Int64, let b = have[.size] as? Int64, a == b,
               let da = src[.modificationDate] as? Date, let db = have[.modificationDate] as? Date,
               abs(da.timeIntervalSince(db)) < 1 {
                stages.append(Stage(id: idx, name: t("prog.archive"), state: .done,
                                    detail: String(format: t("prog.archiveReused"), 1)))
                say(String(format: t("msg.archiveReused"), dest))
                placeAddOnContent(workDir: workDir, in: dest)
                archivePath = dest
                return then(dest)
            }
            try? fm.removeItem(atPath: to)
            do {
                try fm.copyItem(atPath: romfsImage, toPath: to)
                // The running stage is updated in place: there is no process here whose progress
                // events would move it, and appending a second stage of the same name read as a
                // duplicate in the stage list.
                if let i = stages.firstIndex(where: { $0.id == idx }) {
                    stages[i].state = .done; stages[i].detail = v
                }
                say(String(format: t("msg.archiveLog"), romfsImage, dest))
                placeAddOnContent(workDir: workDir, in: dest)
                archivePath = dest
                return then(dest)
            } catch {
                if let i = stages.firstIndex(where: { $0.id == idx }) {
                    stages[i].state = .failed; stages[i].detail = error.localizedDescription
                }
                doneNote = String(format: t("msg.archiveFailed"), 1)
                running = false; cleanupStaging()
            }
            return
        }
        // dest/romfs.img: one file, which main.m's per-game lookup takes before any folder.
        let engine = EngineLayout.root(repo.path)
        let romfsPy = deps.pythonPath.isEmpty ? "/usr/bin/python3" : deps.pythonPath
        let launch = ProcessLaunch(executable: romfsPy, arguments: [engine + "/" + RepoLayout.romfsImageTool, "--reuse", romfs, dest + "/romfs.img"],
                                   environment: ["PATH": BuildCommands.toolPath("/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin", python: romfsPy), "PYTHONPATH": engine + "/dm/tools"]
                                       .merging(BundledTools.environment(for: romfsPy)) { $1 },
                                   groupPython: romfsPy)
        let onExit: @Sendable (Int32) -> Void = { [weak self] st in hop {
            guard let self else { return }
            let cancelled = self.stopping
            let succeeded = st == 0 && !cancelled
            self.stopping = false
            if succeeded {
                self.archivePath = dest
                RomFSArchive.writeStamp(source: romfs, version: v, to: dest + "/.packstamp")
                self.placeAddOnContent(workDir: workDir, in: dest)
            }
            if let i = self.stages.firstIndex(where: { $0.id == idx }) {
                self.stages[i].state = succeeded ? .done : .failed
                self.stages[i].detail = succeeded
                    ? String(format: self.t("prog.archiveDone"), dest)
                    : String(format: self.t("msg.archiveFailed"), st)
            }
            if succeeded { return then(dest) }
            self.cleanupStaging()
            self.running = false
            self.done = false
            if cancelled { self.resetProgress() }
            self.doneNote = cancelled ? self.t("msg.stopped") : String(format: self.t("msg.archiveFailed"), st)
        }}
        do {
            proc = try runner.start(launch, onOutput: { @Sendable [weak self] d in
                guard let s = String(data: d, encoding: .utf8) else { return }
                hop { self?.append(s) }
            }, onExit: onExit)
        } catch {
            if let i = stages.firstIndex(where: { $0.id == idx }) {
                stages[i].state = .failed; stages[i].detail = t("msg.archiveNoStart")
            }
            running = false; doneNote = t("msg.archiveNoStart"); cleanupStaging()
        }
    }
}
