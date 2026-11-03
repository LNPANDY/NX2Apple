import Foundation
import NXCore

/// Deleting a game from the library (#559): what goes, what stays, and doing it. Everything goes to the Trash, so a wrong
/// click can be undone in the Finder. The game's own files (the NSP, XCI and update packages it was built from) are never
/// touched. Its saves go only when the player chooses so.
struct GameDeletion: Equatable {
    /// One thing that is deleted, with the paths it is made of and their size on disk.
    struct Item: Identifiable, Equatable {
        enum Kind: String, CaseIterable { case macApp, ipa, iosApp, archive, shellFramework, buildFolder, log, saves }
        var kind: Kind
        var paths: [String]
        var bytes: Int64 = 0
        var id: String { kind.rawValue }
    }

    var titleID: String
    /// What is deleted with the game, in the order the question lists it. The saves are apart.
    var items: [Item]
    /// The saves, nil when the game has none on this Mac.
    var saves: Item?
    /// The shared app's folder when the game is in it: the game leaves its list (shell.json), so the next install of the
    /// shared app leaves it out.
    var shellRoot: String?

    /// The plan for one game. Reads only, measures the sizes when `measure` (off the main thread: a build folder can hold
    /// tens of GB).
    static func plan(for game: LibraryGame, shellRoot: String, home: String = NSHomeDirectory(),
                     support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
                     measure: Bool = true) -> GameDeletion {
        let fm = FileManager.default
        func exists(_ path: String) -> Bool { !path.isEmpty && fm.fileExists(atPath: path) }
        var items: [Item] = []
        if exists(game.appPath) { items.append(Item(kind: .macApp, paths: [game.appPath])) }
        if game.hasIPA { items.append(Item(kind: .ipa, paths: [game.ipaPath])) }
        // An app of its own (an older iPhone build). The shared app holds other games too and is never deleted here.
        if game.hasIOSApp && ShellInstall.paths(ofApp: game.iosAppPath) == nil { items.append(Item(kind: .iosApp, paths: [game.iosAppPath])) }
        // The game data the shared app's install sends: <output folder>/games/<title ID>, nothing above it.
        if exists(game.archivePath) && (game.archivePath as NSString).lastPathComponent == game.titleID {
            items.append(Item(kind: .archive, paths: [game.archivePath]))
        }
        var root: String?
        if !shellRoot.isEmpty, ShellLibrary.load(root: shellRoot).games.contains(where: { $0.titleID == game.titleID }) {
            root = shellRoot
            let mirror = ShellInstall.mirroredFramework(root: shellRoot, titleID: game.titleID)
            items.append(Item(kind: .shellFramework, paths: exists(mirror) ? [mirror] : []))
        }
        let build = BuildFolder.location(for: game)
        let sources = Set(game.inputs.values.flatMap { $0 }.map(BuildFolder.resolved))
        if let build {
            // Everything in it but the Mac development build's save (run/), which goes with the saves.
            let names = ((try? fm.contentsOfDirectory(atPath: build)) ?? []).filter { $0 != "run" }.sorted()
            let paths = names.map { build + "/" + $0 }.filter { path in !sources.contains { $0 == path || $0.hasPrefix(path + "/") } }
            items.append(Item(kind: .buildFolder, paths: paths))
        }
        let logs = GameLog.folders(appPath: game.appPath, home: home).flatMap { folder in
            [game.titleID + ".log", game.titleID + ".prev.log"].map { folder.appendingPathComponent($0).path }
        }.filter(exists)
        if !logs.isEmpty { items.append(Item(kind: .log, paths: logs)) }

        let mac = SaveTransfer.macSave(titleID: game.titleID, appPath: game.appPath, support: support)
        var saves = [mac.save, mac.legacy ?? SaveTransfer.legacyMacSave(titleID: game.titleID, support: support)].flatMap { save in
            [save.path, save.path + "_device", save.path + "-backups"]
        }
        if let build { saves.append(build + "/run") }
        saves = Array(Set(saves)).sorted().filter(exists)
        var plan = GameDeletion(titleID: game.titleID, items: items, saves: saves.isEmpty ? nil : Item(kind: .saves, paths: saves), shellRoot: root)
        if measure {
            for i in plan.items.indices { plan.items[i].bytes = plan.items[i].paths.reduce(0) { $0 + BuildFolder.size($1) } }
            plan.saves?.bytes = saves.reduce(0) { $0 + BuildFolder.size($1) }
        }
        return plan
    }

    /// Moves every path of the plan to the Trash, the saves only when `saves`, and takes the game out of the shared app's
    /// list. The library entry is the caller's. Returns the paths that could not be moved. `trash` is the Finder's Trash;
    /// tests delete instead.
    @discardableResult
    func run(saves: Bool, trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> [String] {
        var failed: [String] = []
        let all = items + (saves ? [self.saves].compactMap { $0 } : [])
        for path in all.flatMap(\.paths) where FileManager.default.fileExists(atPath: path) {
            do { try trash(URL(fileURLWithPath: path)) } catch { failed.append(path) }
        }
        // The build folder itself, once nothing is left in it (its run/ stays with the saves).
        if let folder = items.first(where: { $0.kind == .buildFolder })?.paths.first.map({ ($0 as NSString).deletingLastPathComponent }),
           (try? FileManager.default.contentsOfDirectory(atPath: folder))?.isEmpty == true {
            try? FileManager.default.removeItem(atPath: folder)
        }
        if let shellRoot {
            var library = ShellLibrary.load(root: shellRoot)
            library.games.removeAll { $0.titleID == titleID }
            do { try library.save(root: shellRoot) } catch { failed.append(ShellLibrary.stateFile(root: shellRoot)) }
        }
        return failed
    }
}
