import Foundation
import NXCore

// A game chosen as a folder of its files (GameFolder, LNPANDY/NX2Apple#512 and #445): how Switch 2 games come. The rows show what the
// folder holds and are not picked one by one, the keys row says no keys are needed, and the build passes the folder to the script
// with no -k (BuildStore+Run.swift).

extension BuildStore {
    /// The folder's rows, or the reason on the base row. Called by `scan(folder:)` when `GameFolder.isCandidate` says so.
    package func takeGameFolder(_ folder: String) {
        let resolved = GameFolder.resolve(folder)
        gameDir = (resolved as NSString).pathExtension.lowercased() == "nup" ? (resolved as NSString).deletingLastPathComponent : resolved   // a NUP: its folder
        gameFolder = nil
        gameFolderRefused = false
        for i in slots.indices { slots[i].paths = []; slots[i].problem = ""; slots[i].note = "" }
        switch GameFolder.scan(resolved) {
        case .failure(let problem):
            refuseGameFolder(gameFolderProblemText(problem))
        case .success(let contents):
            if let why = gameFolderEngineProblem(contents) { refuseGameFolder(why); return }
            gameFolder = contents
            updateSlot("base") { $0.paths = [contents.basePath] }
            updateSlot("update") { $0.paths = contents.newestUpdate.map { [$0.path] } ?? [] }
            updateSlot("dlc") { $0.paths = contents.dlc.map(\.path) }
        }
    }

    /// Back to packages: the folder's rows are emptied, so a picked or dropped package never mixes with them.
    package func leaveGameFolder() {
        guard gameFolder != nil || gameFolderRefused else { return }
        gameFolder = nil
        gameFolderRefused = false
        for i in slots.indices { slots[i].paths = []; slots[i].problem = ""; slots[i].note = "" }
    }

    private func refuseGameFolder(_ why: String) {
        gameFolderRefused = true
        updateSlot("base") { $0.problem = why }
    }

    /// What the engine lacks for this folder: the packer, or a profile for the game. Only an engine without the survey needs the
    /// profile, a newer one builds a game with no profile from a provisional one. nil without an engine yet: the build asks again
    /// before it starts.
    package func gameFolderEngineProblem(_ contents: GameFolder.Contents) -> String? {
        let engine = EngineLayout.root(repo.path)
        guard !engine.isEmpty, FileManager.default.fileExists(atPath: engine + "/dm") else { return nil }
        if contents.nup != nil ? !GameFolder.engineBuildsNUPs(engine) : !GameFolder.engineBuildsFolders(engine) {
            return t(contents.nup != nil ? "folder.engineOldNUP" : "folder.engineOld")
        }
        // A NUP whose package table names no title ID: the script reads it from the code, and checks the profile itself.
        // An engine with the survey builds a game with no profile from a provisional one.
        if contents.hasTitleID, !GameFolder.engineSurveysWithoutProfile(engine), !GameFolder.engineHasProfile(contents.titleID, engineRoot: engine) { return String(format: t("folder.noProfile"), contents.titleIDHex) }
        return nil
    }

    /// The problem as a finished sentence in the current language, with the missing piece named.
    package func gameFolderProblemText(_ problem: GameFolder.Problem) -> String {
        switch problem {
        case .missing(let piece): return String(format: t("folder.problem.missing"), piece)
        case .noBaseFolder: return t("folder.problem.noBase")
        case .unreadableNPDM: return t("folder.problem.npdm")
        case .notBaseTitle(let tid): return String(format: t("folder.problem.notBase"), String(format: "%016llX", tid))
        case .packageBeside(let name): return String(format: t("folder.problem.package"), name)
        case .dlcName(let name): return String(format: t("folder.problem.dlcName"), name)
        case .notDLC(let name, _): return String(format: t("folder.problem.notDLC"), name)
        case .dlcRomFS(let name, let count): return String(format: t("folder.problem.dlcRomFS"), name, count)
        case .notNUP(let name): return String(format: t("folder.problem.notNUP"), name)
        case .nupPartial(let name): return String(format: t("folder.problem.nupPartial"), name)
        case .severalNUPs(let count): return String(format: t("folder.problem.severalNUPs"), count)
        }
    }

    /// A row's text while a game folder is chosen, nil otherwise (the row then shows its files as for packages).
    package func gameFolderRowText(_ id: String) -> String? {
        guard let f = gameFolder else { return nil }
        switch id {
        case "base":
            if f.nup == nil { return String(format: t("folder.base"), f.titleIDHex) }
            return f.hasTitleID ? String(format: t("folder.nupBase"), f.titleIDHex) : t("folder.nupBaseNoID")
        case "update":
            guard let newest = f.newestUpdate else { return t("data.notSelectedOptional") }
            return f.updates.count > 1 ? String(format: t("folder.updates"), newest.version, f.updates.count) : String(format: t("folder.update"), newest.version)
        case "dlc": return f.dlc.isEmpty ? t("data.notSelectedDlc") : String(format: t("folder.dlc"), f.dlc.count)
        case "keys": return t("folder.keys")
        default: return nil
        }
    }

    /// The base game and the keys are there, or a game folder that needs no keys.
    package var inputsReady: Bool { gameFolder != nil ? slot("base").ok : slot("base").ok && slot("keys").ok }

    /// The key of the work folder (`<key>_build`): the folder's title ID, else the base package's (TitleID.buildKey).
    package var buildKey: String {
        if let selectedTitleID { return selectedTitleID }
        guard let f = gameFolder else { return TitleID.buildKey(basePath) }
        return f.hasTitleID ? f.titleIDHex : TitleID.buildKey(f.scriptInput)
    }

    /// The folder the build's output goes beside when no Save to folder is chosen: the game folder, else the base package's folder.
    package var inputFolder: String { gameFolder?.folder ?? (basePath as NSString).deletingLastPathComponent }

    /// The game's title ID as 16 hex digits, when the inputs tell it.
    package var gameTitleID: String? {
        if let selectedTitleID { return selectedTitleID }
        if let f = gameFolder { return f.hasTitleID ? f.titleIDHex : nil }
        return TitleID.parse(basePath).map { String(format: "%016llX", $0) }
    }

    /// The chosen game is a Switch 2 game by its engine profile (GameFolder.profileIsSwitch2): the Builds page says how far the engine's support goes.
    package var isSwitch2Game: Bool {
        guard let tid = gameTitleID else { return false }
        return GameFolder.profileIsSwitch2(tid, engineRoot: EngineLayout.root(repo.path))
    }

    /// A name for the game in messages and the shared app: the profile's for a game folder (it has no control data), else the base package's file name.
    package var gameName: String {
        if let selectedTitleID, let tid = UInt64(selectedTitleID, radix: 16) {
            return GameFolder.profileName(tid, engineRoot: EngineLayout.root(repo.path)) ?? selectedTitleID
        }
        if let f = gameFolder {
            let fallback = f.nup.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? (f.folder as NSString).lastPathComponent
            return f.hasTitleID ? GameFolder.profileName(f.titleID, engineRoot: EngineLayout.root(repo.path)) ?? fallback : fallback
        }
        return ((basePath as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}
