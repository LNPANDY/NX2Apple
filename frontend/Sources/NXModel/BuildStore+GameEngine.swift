import Foundation
import NXCore

// A game engine file (.nxgame, tools/game_archive.py): an optional input row that brings a game's support the launcher's engine does
// not have yet. Picked once per game and kept (GameArchiveLibrary). Before a build that uses it, the store checks it against the base
// game and the engine, and asks the player when it is used for the first time or when something does not match. The build then runs
// from a copy of the engine with the archive applied (GameArchiveTree), never from the launcher's engine itself.

/// The question before a build with a game engine file: shown when the file is used for the first time or does not match.
package struct GameEngineQuestion: Equatable {
    package var archive: GameArchiveLibrary.Stored
    package var firstUse: Bool
    package var warnings: [GameArchive.Warning]
}

extension BuildStore {
    nonisolated package static let gameEngineAcceptedKey = "gameEngineAccepted"

    /// The title ID in the base game's file name.
    package var baseTitleID: UInt64? { basePath.isEmpty ? nil : TitleID.parse(basePath) }

    /// The game engine file for the chosen base game: the one kept for its title ID, or the last one picked when the base game's file
    /// name has no title ID.
    package var gameEngine: GameArchiveLibrary.Stored? {
        if let tid = baseTitleID { return gameEngines[String(format: "%016llX", tid)] }
        return pickedGameEngine.flatMap { gameEngines[$0] }
    }

    /// The row's text: the file's game, its title ID and its author, or why the last pick was not taken.
    package var gameEngineSummary: String {
        if !gameEngineProblem.isEmpty { return gameEngineProblem }
        guard let a = gameEngine else { return t("data.engineFileNone") }
        let m = a.manifest
        return String(format: t("data.engineFileSummary"), m.name.isEmpty ? m.titleID : m.name, m.titleID, m.author.isEmpty ? "?" : m.author)
    }

    package func pickGameEngine() {
        let picked = choosePaths(FilePick(allowsMultiple: false, fileTypes: [GameArchive.fileExtension], message: t("data.engineFilePanel")))
        guard let path = picked.first else { return }
        takeGameEngine(path)
    }

    /// Unpacks, checks and keeps the file as its game's game engine file.
    package func takeGameEngine(_ path: String) {
        gameEngineProblem = ""
        do {
            let s = try GameArchiveLibrary.add(path, root: gameEngineRoot, runner: runner)
            gameEngines[s.titleID] = s
            pickedGameEngine = s.titleID
            if let tid = baseTitleID, String(format: "%016llX", tid) != s.titleID {
                gameEngineProblem = String(format: t("data.engineFileOtherGame"), s.manifest.name, s.titleID)
            }
        } catch {
            gameEngineProblem = String(format: t("data.engineFileBad"), gameEngineProblemText(error))
        }
    }

    package func clearGameEngine() {
        gameEngineProblem = ""
        guard let a = gameEngine else { return }
        GameArchiveLibrary.remove(titleID: a.titleID, root: gameEngineRoot)
        gameEngines[a.titleID] = nil
        if pickedGameEngine == a.titleID { pickedGameEngine = nil }
    }

    func gameEngineProblemText(_ error: Error) -> String {
        switch error as? GameArchive.Problem {
        case .unpack?, .noManifest?: return t("engineFile.problemNotArchive")
        case .badManifest?, .format?, .badTitleID?: return t("engineFile.problemManifest")
        case .missing?, .digest?, .unlisted?, .outside?, .noGameFolder?: return t("engineFile.problemFiles")
        case nil: return error.localizedDescription
        }
    }

    var acceptedGameEngines: Set<String> { Set(defaults.stringArray(forKey: Self.gameEngineAcceptedKey) ?? []) }

    /// Before a build: true when it must wait, for the player's answer (`gameEngineQuestion` is set) or because the file is for
    /// another game (the note says so). A build the player confirmed passes once.
    func askAboutGameEngine() -> Bool {
        guard let a = gameEngine else { return false }
        if gameEngineConfirmed { gameEngineConfirmed = false; return false }
        guard (try? GameArchive.verify(folder: a.folder)) != nil else {
            gameEngines[a.titleID] = nil
            done = false; doneNote = t("engineFile.changed")
            return true
        }
        let update: Int?
        if updatePath.isEmpty { update = 0 } else {
            let v = TitleID.updateVersion((updatePath as NSString).lastPathComponent)
            update = v == 0 ? nil : v
        }
        switch GameArchive.check(a.manifest, baseTitleID: baseTitleID, updateVersion: update, engine: .of(repo: repo.path)) {
        case .otherGame(let archive, let base):
            done = false; doneNote = String(format: t("engineFile.blockedOtherGame"), archive, base)
            return true
        case .warnings(let warnings):
            let first = !acceptedGameEngines.contains(a.sha256)
            if !first && warnings.isEmpty { gameEngineWarnings = []; return false }
            gameEngineQuestion = GameEngineQuestion(archive: a, firstUse: first, warnings: warnings)
            return true
        }
    }

    /// Build: the file is remembered as accepted and the build starts with it.
    package func acceptGameEngine() {
        guard let q = gameEngineQuestion else { return }
        gameEngineQuestion = nil
        defaults.set(Array(acceptedGameEngines.union([q.archive.sha256])).sorted(), forKey: Self.gameEngineAcceptedKey)
        gameEngineWarnings = q.warnings
        gameEngineConfirmed = true
        startBuild()
    }

    package func declineGameEngine() { gameEngineQuestion = nil }

    /// The question's text, in the current language.
    package func gameEngineMessage(_ q: GameEngineQuestion) -> String {
        var parts: [String] = []
        if q.firstUse {
            let m = q.archive.manifest
            let files = m.patched.isEmpty ? t("engineFile.noPatchedFiles") : m.patched.joined(separator: ", ")
            parts.append(String(format: t("engineFile.firstUse"), m.name, m.titleID, m.author.isEmpty ? "?" : m.author, files))
            if !m.notes.isEmpty { parts.append(m.notes) }
        }
        parts += q.warnings.map(warningText)
        return parts.joined(separator: "\n\n")
    }

    func warningText(_ w: GameArchive.Warning) -> String {
        func versions(_ vs: [Int]) -> String { vs.map { "v\($0)" }.joined(separator: ", ") }
        switch w {
        case .unknownTitle: return t("engineFile.warnUnknownTitle")
        case .otherEngine(let archive, let mine):
            return String(format: t("engineFile.warnOtherEngine"), String(archive.prefix(12)), mine.isEmpty ? "?" : String(mine.prefix(12)))
        case .otherUpdate(let v, let registered):
            return String(format: t("engineFile.warnOtherUpdate"), versions(registered), v == 0 ? t("engineFile.updateNone") : "v\(v)")
        }
    }

    /// The engine the build runs from: the launcher's (`engineRoot`) without a game engine file, else a copy with the file applied.
    /// nil when the copy failed (the build has failed with the reason).
    func engineForBuild(_ engineRoot: String) -> String? {
        gameEngineTree = nil
        guard let a = gameEngine else { return engineRoot }
        let m = a.manifest
        say(String(format: t("engineFile.using"), m.name, m.titleID, String(m.baseLabel.prefix(12))))
        for w in gameEngineWarnings { say("⚠︎ " + warningText(w)) }
        gameEngineWarnings = []
        let dest = gameEngineTreeRoot + "/" + a.titleID + "/engine"
        do {
            try GameArchiveTree.make(engineRoot: engineRoot, archive: a, into: dest, runner: runner)
        } catch GameArchiveTree.Problem.patch(let output) {
            say(output)
            fail(String(format: t("engineFile.patchFailed"), m.patched.joined(separator: ", ")))
            return nil
        } catch {
            fail(String(format: t("engineFile.copyFailed"), String(describing: error)))
            return nil
        }
        gameEngineTree = dest
        return dest
    }

    /// After the build: the copy goes when it succeeded or was stopped, and stays for a look when it failed (the next build of the
    /// game replaces it).
    func finishGameEngineTree(keep: Bool) {
        guard let tree = gameEngineTree else { return }
        gameEngineTree = nil
        if keep { say(String(format: t("engineFile.kept"), tree)) }
        else { try? FileManager.default.removeItem(atPath: tree) }
    }
}
