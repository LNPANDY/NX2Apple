import Foundation
import CryptoKit

/// A game engine archive (`.nxgame`): one game's support made from an nxnative repository by `tools/game_archive.py`, for a game the
/// launcher's engine does not support yet. A ZIP of `manifest.json`, `engine.patch` (the game's changes to shared engine files, absent
/// when there are none) and `game/dm/games/<TitleID>/` (the game's folder).
///
/// This file reads and checks an archive: pure functions and the unpacking. `GameArchiveTree` makes the engine tree a build runs from.
package enum GameArchive {
    package static let fileExtension = "nxgame"
    package static let format = 1
    package static let patchName = "engine.patch"
    package static let gamePrefix = "game/"

    package struct Base: Decodable, Equatable {
        package var commit: String
        package var remote: String
        package var pin: String?
        package var engineID: String?

        enum CodingKeys: String, CodingKey { case commit, remote, pin; case engineID = "engine_id" }

        package init(commit: String = "", remote: String = "", pin: String? = nil, engineID: String? = nil) {
            self.commit = commit; self.remote = remote; self.pin = pin; self.engineID = engineID
        }

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            commit = try c.decodeIfPresent(String.self, forKey: .commit) ?? ""
            remote = try c.decodeIfPresent(String.self, forKey: .remote) ?? ""
            pin = try c.decodeIfPresent(String.self, forKey: .pin)
            engineID = try c.decodeIfPresent(String.self, forKey: .engineID)
        }
    }

    package struct Commit: Decodable, Equatable {
        package var hash: String
        package var subject: String
        package init(hash: String, subject: String) { self.hash = hash; self.subject = subject }
    }

    package struct Manifest: Decodable, Equatable {
        package var format: Int
        package var titleID: String
        package var name: String
        /// The update versions the game's game.tsv registers.
        package var updates: [Int]
        package var base: Base
        package var commits: [Commit]
        /// The shared engine files `engine.patch` changes.
        package var patched: [String]
        package var author: String
        package var notes: String
        package var created: String
        /// SHA-256 of every file of the archive but the manifest.
        package var files: [String: String]

        enum CodingKeys: String, CodingKey {
            case format, name, updates, base, commits, patched, author, notes, created, files
            case titleID = "title_id"
        }

        package init(format: Int = GameArchive.format, titleID: String, name: String, updates: [Int] = [], base: Base = Base(), commits: [Commit] = [],
                     patched: [String] = [], author: String = "", notes: String = "", created: String = "", files: [String: String] = [:]) {
            self.format = format; self.titleID = titleID; self.name = name; self.updates = updates; self.base = base; self.commits = commits
            self.patched = patched; self.author = author; self.notes = notes; self.created = created; self.files = files
        }

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            format = try c.decode(Int.self, forKey: .format)
            titleID = try c.decode(String.self, forKey: .titleID)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            updates = try c.decodeIfPresent([Int].self, forKey: .updates) ?? []
            base = try c.decodeIfPresent(Base.self, forKey: .base) ?? Base()
            commits = try c.decodeIfPresent([Commit].self, forKey: .commits) ?? []
            patched = try c.decodeIfPresent([String].self, forKey: .patched) ?? []
            author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
            notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
            created = try c.decodeIfPresent(String.self, forKey: .created) ?? ""
            files = try c.decodeIfPresent([String: String].self, forKey: .files) ?? [:]
        }

        /// The game's folder inside the archive.
        package var gameFolder: String { GameArchive.gamePrefix + "dm/games/" + titleID }
        package var hasPatch: Bool { files[GameArchive.patchName] != nil }
        /// What the launcher compares with its own engine: the engine ID when the archive has one, else the upstream commit.
        package var baseLabel: String { base.engineID ?? base.pin ?? base.commit }
    }

    /// Why an archive cannot be used.
    package enum Problem: Error, Equatable {
        case unpack                       // not a ZIP, or the disk is full
        case noManifest
        case badManifest(String)          // not the JSON of a manifest
        case format(Int)                  // made by a newer tool
        case badTitleID(String)
        case missing(String)              // listed, not in the archive
        case digest(String)               // its SHA-256 is not the listed one
        case unlisted(String)             // in the archive, not listed
        case outside(String)              // listed outside the game's folder
        case noGameFolder
    }

    /// A title ID as the archive and the engine write it: 16 upper-case hexadecimal digits.
    package static func isTitleID(_ s: String) -> Bool {
        s.count == 16 && s.allSatisfy { $0.isHexDigit && !$0.isLowercase }
    }

    package static func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// The SHA-256 of a file, read in pieces. nil when it cannot be read.
    package static func digest(ofFile path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        var sha = SHA256()
        do {
            while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { sha.update(data: chunk) }   // nil at the end
        } catch { return nil }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    package static func parse(_ data: Data) throws -> Manifest {
        let m: Manifest
        do { m = try JSONDecoder().decode(Manifest.self, from: data) } catch { throw Problem.badManifest(String(describing: error)) }
        guard m.format == format else { throw Problem.format(m.format) }
        guard isTitleID(m.titleID) else { throw Problem.badTitleID(m.titleID) }
        return m
    }

    /// Unpacks a `.nxgame` into `folder` (made empty first) with ditto, as the engine and app updates are unpacked.
    package static func unpack(_ archive: String, into folder: String, runner: ProcessRunner = SystemProcessRunner()) throws {
        let fm = FileManager.default
        try? fm.removeItem(atPath: folder)
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let r = runner.capture(ProcessLaunch(executable: "/usr/bin/ditto", arguments: ["-x", "-k", archive, folder]))
        guard r.started, r.status == 0 else { throw Problem.unpack }
    }

    /// The manifest of an unpacked archive, after checking every file against it: each listed file is there with its SHA-256, none
    /// is there unlisted, and all but the patch are in the game's folder.
    package static func verify(folder: String) throws -> Manifest {
        guard let data = FileManager.default.contents(atPath: folder + "/manifest.json") else { throw Problem.noManifest }
        let m = try parse(data)
        let prefix = m.gameFolder + "/"
        for (name, sum) in m.files.sorted(by: { $0.key < $1.key }) {
            guard name == patchName || name.hasPrefix(prefix), !name.contains("..") else { throw Problem.outside(name) }
            guard let have = digest(ofFile: folder + "/" + name) else { throw Problem.missing(name) }
            guard have == sum.lowercased() else { throw Problem.digest(name) }
        }
        for name in files(in: folder) where name != "manifest.json" && m.files[name] == nil { throw Problem.unlisted(name) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder + "/" + m.gameFolder, isDirectory: &isDir), isDir.boolValue else { throw Problem.noGameFolder }
        return m
    }

    /// The regular files under `folder`, as paths relative to it, `/`-separated. Finder's `.DS_Store` is not a file of the archive.
    static func files(in folder: String) -> [String] {
        guard let e = FileManager.default.enumerator(atPath: folder) else { return [] }
        var out: [String] = []
        while let rel = e.nextObject() as? String {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: folder + "/" + rel, isDirectory: &isDir), !isDir.boolValue,
               (rel as NSString).lastPathComponent != ".DS_Store" { out.append(rel) }
        }
        return out.sorted()
    }

    // MARK: The checks before a build

    /// The engine a build would use: its ID (`<pin>-<12 hex>`) and the upstream commit it is built on, empty when unknown.
    package struct EngineIdentity: Equatable {
        package var engineID: String
        package var pin: String
        package init(engineID: String, pin: String) { self.engineID = engineID; self.pin = pin }

        /// Read from the engine tree: `.engine-id` and `.upstream-ref` of an installed engine, or for a checkout the pin and the
        /// series of the repository (the same ID `tools/engine.py` gives the tree it builds).
        package static func of(repo: String) -> EngineIdentity {
            let root = EngineLayout.root(repo)
            func read(_ path: String) -> String { ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            var id = read(root + "/.engine-id"), pin = read(root + "/.upstream-ref")
            if pin.isEmpty { pin = read(repo + "/.upstream-ref") }
            if id.isEmpty, !pin.isEmpty, let key = EngineLayout.stampKey(repo) { id = pin + "-" + key.prefix(12) }
            return EngineIdentity(engineID: id, pin: pin)
        }
    }

    /// What the launcher tells the player before a build with an archive.
    package enum Warning: Equatable {
        /// The base game's file name has no title ID, so the archive's game cannot be compared.
        case unknownTitle
        /// The archive was made against another engine (archive's, this engine's).
        case otherEngine(String, String)
        /// The chosen update (its version, 0 for none) is not one the archive registers.
        case otherUpdate(Int, [Int])
    }

    package enum Verdict: Equatable {
        /// The archive is for another game (archive's title ID, the base game's).
        case otherGame(String, String)
        case warnings([Warning])
    }

    /// The archive against this build: another game blocks it, the rest are warnings the player can accept.
    /// - Parameters:
    ///   - baseTitleID: the title ID in the base game's file name, nil when it has none.
    ///   - updateVersion: the version of the chosen update, 0 without one, nil when its file name has no version.
    package static func check(_ m: Manifest, baseTitleID: UInt64?, updateVersion: Int?, engine: EngineIdentity) -> Verdict {
        var warnings: [Warning] = []
        if let tid = baseTitleID {
            let base = String(format: "%016llX", tid)
            if base != m.titleID { return .otherGame(m.titleID, base) }
        } else {
            warnings.append(.unknownTitle)
        }
        let same: Bool
        if let id = m.base.engineID, !engine.engineID.isEmpty { same = id == engine.engineID }
        else if let pin = m.base.pin, !engine.pin.isEmpty { same = pin == engine.pin }
        else { same = false }
        if !same { warnings.append(.otherEngine(m.baseLabel, engine.engineID.isEmpty ? engine.pin : engine.engineID)) }
        if let v = updateVersion, !m.updates.isEmpty, !m.updates.contains(v) { warnings.append(.otherUpdate(v, m.updates)) }
        return .warnings(warnings)
    }

    /// The line a build made with an archive adds to `dm/fork_patches.txt`: the app's Info.plist and its log name the archive.
    package static func forkPatchLine(titleID: String, sha256: String) -> String { "nxgame:\(titleID)-\(sha256.prefix(12))" }
}
