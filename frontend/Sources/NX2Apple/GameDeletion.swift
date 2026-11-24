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

    /// The plan for one game (all builds when `upstream == nil`, or a single engine's build when `upstream` is given).
    /// Reads only, measures the sizes when `measure` (off the main thread: a build folder can hold tens of GB).
    static func plan(for game: LibraryGame, shellRoot: String, upstream: EngineUpstreamKind? = nil, home: String = NSHomeDirectory(),
                     support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
                     measure: Bool = true) -> GameDeletion {
        let fm = FileManager.default
        func exists(_ path: String) -> Bool { !path.isEmpty && fm.fileExists(atPath: path) }
        var items: [Item] = []

        if let upstream {
            let targetMacPath = game.macBuild(for: upstream)?.appPath ?? ""
            if exists(targetMacPath) { items.append(Item(kind: .macApp, paths: [targetMacPath])) }
            if let targetIPA = game.ipaBuilds[upstream.rawValue], exists(targetIPA),
               (targetIPA as NSString).lastPathComponent.lowercased() != "nx2apple.ipa" {
                items.append(Item(kind: .ipa, paths: [targetIPA]))
            }
            let builds = BuildFolder.locations(for: game, upstream: upstream)
            let sources = Set(game.inputs.values.flatMap { $0 }.map(BuildFolder.resolved))
            var buildPaths: [String] = []
            for build in builds {
                let names = ((try? fm.contentsOfDirectory(atPath: build)) ?? []).filter { $0 != "run" }.sorted()
                buildPaths += names.map { build + "/" + $0 }.filter { path in !sources.contains { $0 == path || $0.hasPrefix(path + "/") } }
            }
            if !buildPaths.isEmpty { items.append(Item(kind: .buildFolder, paths: buildPaths)) }

            let otherLogs = Set(
                game.sortedMacBuilds.filter { $0.upstream != upstream && exists($0.appPath) }.flatMap { build in
                    GameLog.folders(appPath: build.appPath, home: home).flatMap { folder in
                        [game.titleID + ".log", game.titleID + ".prev.log"].map { folder.appendingPathComponent($0).path }
                    }
                }
            )
            let logs = (exists(targetMacPath) ? GameLog.folders(appPath: targetMacPath, home: home) : []).flatMap { folder in
                [game.titleID + ".log", game.titleID + ".prev.log"].map { folder.appendingPathComponent($0).path }
            }.filter { exists($0) && !otherLogs.contains($0) }
            if !logs.isEmpty { items.append(Item(kind: .log, paths: logs)) }

            var saves: [String] = builds.map { $0 + "/run" }
            let engine = SaveEngines.forUpstream(upstream)
            if upstream.sharesSaveWithNxnative {
                let otherSharesSave = game.sortedMacBuilds.contains { $0.upstream != upstream && $0.upstream.sharesSaveWithNxnative && exists($0.appPath) }
                if !otherSharesSave, exists(targetMacPath) {
                    saves += Self.managedSavePaths(titleID: game.titleID, appPath: targetMacPath, engine: engine, support: support)
                }
            } else if engine.managesSavesInLauncher {
                if exists(targetMacPath) {
                    saves += Self.managedSavePaths(titleID: game.titleID, appPath: targetMacPath, engine: engine, support: support)
                }
            } else {
                saves += engine.deletionPaths(titleID: game.titleID, support: support)
            }
            saves = Array(Set(saves)).sorted().filter(exists)
            var plan = GameDeletion(titleID: game.titleID, items: items, saves: saves.isEmpty ? nil : Item(kind: .saves, paths: saves), shellRoot: nil)
            if measure {
                for i in plan.items.indices { plan.items[i].bytes = plan.items[i].paths.reduce(0) { $0 + BuildFolder.size($1) } }
                plan.saves?.bytes = saves.reduce(0) { $0 + BuildFolder.size($1) }
            }
            return plan
        }

        let macPaths = game.allMacAppPaths.filter(exists)
        if !macPaths.isEmpty { items.append(Item(kind: .macApp, paths: macPaths)) }
        let ipaPaths = game.allIPAPaths.filter { exists($0) && ($0 as NSString).lastPathComponent.lowercased() != "nx2apple.ipa" }
        if !ipaPaths.isEmpty { items.append(Item(kind: .ipa, paths: ipaPaths)) }
        // An app of its own (an older iPhone build). The shared app holds other games too and is never deleted here.
        if game.hasIOSApp && ShellInstall.paths(ofApp: game.iosAppPath) == nil { items.append(Item(kind: .iosApp, paths: [game.iosAppPath])) }
        // The game data the shared app's install sends: <output folder>/games/<title ID> or <output folder>/games/<SafeName>
        if exists(game.archivePath) {
            let archClean = (game.archivePath as NSString).standardizingPath
            let archBN = (archClean as NSString).lastPathComponent
            let parent = (archClean as NSString).deletingLastPathComponent
            let archParentBN = (parent as NSString).lastPathComponent
            let tidUpper = game.titleID.uppercased()
            let titleIDFile = archClean + "/.titleid"
            let claimed = (try? String(contentsOfFile: titleIDFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

            var shouldDelete = false
            if archBN.uppercased() == tidUpper {
                shouldDelete = true
            } else if let claimed, claimed == tidUpper {
                shouldDelete = true
            } else if archParentBN == "games" && (claimed == nil || claimed!.isEmpty) && RomFSArchive.primaryImagePath(in: archClean) != nil {
                shouldDelete = true
            }
            if shouldDelete {
                var paths = [game.archivePath]
                if archParentBN == "games" {
                    for dir in RomFSArchive.archiveDirectories(forTitleID: game.titleID, gamesRoot: parent, fm: fm) {
                        if !paths.contains(dir) { paths.append(dir) }
                    }
                }
                items.append(Item(kind: .archive, paths: paths))
            }
        }
        var root: String?
        if !shellRoot.isEmpty, ShellLibrary.load(root: shellRoot).games.contains(where: { $0.titleID == game.titleID }) {
            root = shellRoot
            let mirror = ShellInstall.mirroredFramework(root: shellRoot, titleID: game.titleID)
            items.append(Item(kind: .shellFramework, paths: exists(mirror) ? [mirror] : []))
        }
        let builds = BuildFolder.locations(for: game)
        let sources = Set(game.inputs.values.flatMap { $0 }.map(BuildFolder.resolved))
        var buildPaths: [String] = []
        for build in builds {
            // Everything in it but the Mac development build's save (run/), which goes with the saves.
            let names = ((try? fm.contentsOfDirectory(atPath: build)) ?? []).filter { $0 != "run" }.sorted()
            buildPaths += names.map { build + "/" + $0 }.filter { path in !sources.contains { $0 == path || $0.hasPrefix(path + "/") } }
        }
        if !buildPaths.isEmpty {
            items.append(Item(kind: .buildFolder, paths: buildPaths))
        }
        let logApps = macPaths.isEmpty ? [game.appPath] : macPaths
        let logs = Array(Set(logApps.flatMap { app in
            GameLog.folders(appPath: app, home: home).flatMap { folder in
                [game.titleID + ".log", game.titleID + ".prev.log"].map { folder.appendingPathComponent($0).path }
            }
        })).sorted().filter(exists)
        if !logs.isEmpty { items.append(Item(kind: .log, paths: logs)) }

        var saves = logApps.flatMap { app -> [String] in
            let engine = SaveEngines.forApp(app)
            if engine.managesSavesInLauncher {
                return Self.managedSavePaths(titleID: game.titleID, appPath: app, engine: engine, support: support)
            }
            return engine.deletionPaths(titleID: game.titleID, support: support)
        }
        for build in builds { saves.append(build + "/run") }
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
        // Each build folder itself, once nothing is left in it (its run/ stays with the saves).
        let buildFolders = Set(
            (items.first(where: { $0.kind == .buildFolder })?.paths ?? [])
                .map { ($0 as NSString).deletingLastPathComponent }
            + (saves ? (self.saves?.paths ?? []).filter { ($0 as NSString).lastPathComponent == "run" }.map { ($0 as NSString).deletingLastPathComponent } : [])
        )
        for folder in buildFolders where (try? FileManager.default.contentsOfDirectory(atPath: folder))?.isEmpty == true {
            try? FileManager.default.removeItem(atPath: folder)
        }
        if let shellRoot {
            var library = ShellLibrary.load(root: shellRoot)
            library.games.removeAll { $0.titleID == titleID }
            do { try library.save(root: shellRoot) } catch { failed.append(ShellLibrary.stateFile(root: shellRoot)) }
        }
        return failed
    }

    private static func managedSavePaths(titleID: String, appPath: String, engine: any SaveEngine, support: URL) -> [String] {
        let mac = SaveTransfer.macSave(titleID: titleID, appPath: appPath, support: support, engine: engine)
        return [mac.save, mac.legacy ?? engine.defaultSave(titleID: titleID, support: support)].flatMap { save in
            [save.path, save.path + "_device", save.path + "-backups"] + SaveUsers.userPaths(save: save)
        }
    }
}
