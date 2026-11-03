import Foundation

/// The archives the launcher keeps, one per game: `<root>/<TitleID>/<sha256 of the .nxgame>/`, the archive unpacked and checked. A game
/// built again finds its archive there. Picking another archive for the game replaces it.
package enum GameArchiveLibrary {
    /// `~/Library/Application Support/NX2Apple/game-engines`.
    package static var defaultRoot: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory() + "/Library/Application Support"
        return support + "/NX2Apple/game-engines"
    }

    package struct Stored: Equatable {
        package var titleID: String
        /// The SHA-256 of the `.nxgame` file: what the player accepted.
        package var sha256: String
        /// The unpacked archive.
        package var folder: String
        package var manifest: GameArchive.Manifest
    }

    /// Unpacks and checks `archive`, then keeps it as its game's archive (the one kept before for that game goes).
    package static func add(_ archive: String, root: String = defaultRoot, runner: ProcessRunner = SystemProcessRunner()) throws -> Stored {
        guard let sha = GameArchive.digest(ofFile: archive) else { throw GameArchive.Problem.unpack }
        let fm = FileManager.default
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        let incoming = root + "/.incoming-" + UUID().uuidString
        defer { try? fm.removeItem(atPath: incoming) }
        try GameArchive.unpack(archive, into: incoming, runner: runner)
        let m = try GameArchive.verify(folder: incoming)
        let game = root + "/" + m.titleID
        try? fm.removeItem(atPath: game)
        try fm.createDirectory(atPath: game, withIntermediateDirectories: true)
        let dest = game + "/" + sha
        try fm.moveItem(atPath: incoming, toPath: dest)
        return Stored(titleID: m.titleID, sha256: sha, folder: dest, manifest: m)
    }

    /// Every kept archive that still checks out, by title ID.
    package static func load(root: String = defaultRoot) -> [String: Stored] {
        let fm = FileManager.default
        var out: [String: Stored] = [:]
        for tid in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where GameArchive.isTitleID(tid) {
            for sha in ((try? fm.contentsOfDirectory(atPath: root + "/" + tid)) ?? []).sorted() where sha.count == 64 {
                let folder = root + "/" + tid + "/" + sha
                if let m = try? GameArchive.verify(folder: folder), m.titleID == tid {
                    out[tid] = Stored(titleID: tid, sha256: sha, folder: folder, manifest: m)
                    break
                }
            }
        }
        return out
    }

    package static func remove(titleID: String, root: String = defaultRoot) {
        guard GameArchive.isTitleID(titleID) else { return }
        try? FileManager.default.removeItem(atPath: root + "/" + titleID)
    }
}

/// The engine tree a build with an archive runs from: a copy of the launcher's engine in a folder of its own, with only the game being
/// built in `dm/games/`, the archive's game folder and its `engine.patch` applied. The launcher's engine is never written to.
package enum GameArchiveTree {
    package enum Problem: Error, Equatable {
        case copy(String)
        /// `git apply --check` refused the patch: its output.
        case patch(String)
    }

    /// The top-level entries of an engine root a build does not read: a checkout's git folder and build products.
    static func skipped(_ name: String) -> Bool {
        name.hasPrefix(".") && name != ".engine-id" && name != ".upstream-ref"
    }

    /// Makes the tree in `dest` (removed first) and returns it.
    @discardableResult
    package static func make(engineRoot: String, archive: GameArchiveLibrary.Stored, into dest: String,
                             runner: ProcessRunner = SystemProcessRunner()) throws -> String {
        let fm = FileManager.default
        try? fm.removeItem(atPath: dest)
        do {
            try fm.createDirectory(atPath: dest, withIntermediateDirectories: true)
            // copyItem clones on APFS, so a copy of the engine costs little space and time
            for name in try fm.contentsOfDirectory(atPath: engineRoot) where !skipped(name) && name != "dm" {
                try fm.copyItem(atPath: engineRoot + "/" + name, toPath: dest + "/" + name)
            }
            try fm.createDirectory(atPath: dest + "/dm/games", withIntermediateDirectories: true)
            for name in (try? fm.contentsOfDirectory(atPath: engineRoot + "/dm")) ?? [] where name != "games" && name != ".DS_Store" {
                try fm.copyItem(atPath: engineRoot + "/dm/" + name, toPath: dest + "/dm/" + name)
            }
            // dm/games: its own files (game.py, settings.tsv, …), no other game's folder
            let games = engineRoot + "/dm/games"
            for name in (try? fm.contentsOfDirectory(atPath: games)) ?? [] {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: games + "/" + name, isDirectory: &isDir), !isDir.boolValue, name != ".DS_Store" {
                    try fm.copyItem(atPath: games + "/" + name, toPath: dest + "/dm/games/" + name)
                }
            }
            try fm.copyItem(atPath: archive.folder + "/" + archive.manifest.gameFolder, toPath: dest + "/dm/games/" + archive.titleID)
        } catch {
            throw Problem.copy(error.localizedDescription)
        }
        if archive.manifest.hasPatch {
            let patch = archive.folder + "/" + GameArchive.patchName
            // Outside any repository: GIT_CEILING_DIRECTORIES keeps git from taking a repository above the folder for the tree.
            let env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(),
                       "GIT_CEILING_DIRECTORIES": (dest as NSString).deletingLastPathComponent]
            for args in [["apply", "--check", "--verbose", patch], ["apply", patch]] {
                let r = runner.capture(ProcessLaunch(executable: "/usr/bin/git", arguments: args, environment: env, directory: dest, mergesErrors: true))
                guard r.started, r.status == 0 else { throw Problem.patch((r.out + r.err).trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
        }
        let line = GameArchive.forkPatchLine(titleID: archive.titleID, sha256: archive.sha256)
        let list = dest + "/dm/fork_patches.txt"
        var text = (try? String(contentsOfFile: list, encoding: .utf8)) ?? ""
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        try? (text + line + "\n").write(toFile: list, atomically: true, encoding: .utf8)
        return dest
    }
}
