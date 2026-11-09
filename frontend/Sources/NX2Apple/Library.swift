import AppKit
import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// Only paths and presentation metadata live here. Game data stays on its original drive.
struct LibraryGame: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var titleID: String
    var name: String
    var appPath = ""
    var ipaPath = ""
    var archivePath = ""
    var lastTarget = BuildTarget.ios
    var inputs: [String: [String]] = [:]
    var outputDirectory = ""
    /// The folder this game's files were found in, which is what the Build page shows: the parent of a base package a
    /// level down (a "nsp本体" folder inside the game's folder) still holds the update and DLC, so the scan climbs to
    /// the folder that does. Empty for a library written before it was recorded; the base package's folder is used then.
    var sourceFolder = ""
    /// The image of an earlier version, a path: migrateArtwork moves it into `artwork` and empties it. Still read, so an old library loads.
    var artworkPath = ""
    var artwork = GameArtwork()
    var launchOptions: [String: String] = [:]
    var mods: [String] = []   // the mods (folder names in the game's mods folder) switched on
    var iosAppPath = ""
    var installedDevice = ""
    /// The engine's commit (engine/ HEAD: the pin plus the series) the last finished build used (ToolsAge); empty for a build from before it was recorded.
    var toolsCommit = ""
    var titleNames: [String: String] = [:]   // the game's names by language, only what is shown (LibraryGame+Names.swift)
    var customName = ""   // the player's name (Manage > Rename), shown in every language
    var lastPlayed: Date?   // when Play last started the Mac app (the library's Recently played order, #937)
    /// False for a game the library has just added: LaunchSetting personal defaults (#680) are written once, before its first start.
    /// A library written before the defaults existed decodes true, so no existing choice is touched.
    var defaultsApplied = false

    /// An empty path means there is no Mac build. It is not read, because URL(fileURLWithPath:) would make it the current folder.
    private var playableMacBundle: MacGameBundle? {
        guard !appPath.isEmpty, let app = try? MacGameBundle.read(URL(fileURLWithPath: appPath)),
              app.titleID == titleID else { return nil }
        return app
    }
    var isReady: Bool { playableMacBundle != nil }

    /// The package Play opens, never the newer source inputs or an iPhone build.
    var playVersion: String? { playableMacBundle?.version }

    /// Signed and installed on a paired device (installedDevice is its UDID): Play starts it there.
    var onDevice: Bool { !installedDevice.isEmpty && FileManager.default.fileExists(atPath: iosAppPath + "/Info.plist") }

    /// An iPhone or iPad game runs only the cheats that write data. Code writes are refused there (iOS does not allow changing
    /// the game's code), so the Cheats sheet says so for a game that has an iOS build. The switches stay usable: the same game may have a Mac build.
    var cheatsNeedIOSNote: Bool { hasIOSBuild || onDevice }
    var hasIOSBuild: Bool { hasIPA || hasIOSApp }
    var hasIPA: Bool { !ipaPath.isEmpty && FileManager.default.fileExists(atPath: ipaPath) }
    var hasIOSApp: Bool { !iosAppPath.isEmpty && FileManager.default.fileExists(atPath: iosAppPath + "/Info.plist") }
    /// An iPhone build made before the shared app: a single IPA, or an app of its own. It stays in the library and Build makes
    /// the game again for the shared app, which then replaces it.
    var isOlderIOSBuild: Bool { hasIOSBuild && !(hasIOSApp && ShellInstall.paths(ofApp: iosAppPath) != nil) }

    /// What the hero's primary button does: play the Mac app, open the installed iPhone app, else build (an IPA alone is not a reason to show anything else).
    enum Primary: Equatable { case play, openOnDevice, build }
    var primary: Primary { isReady ? .play : (onDevice ? .openOnDevice : .build) }

    /// What "Reveal in Finder" shows: the Mac app if it exists, else the IPA, else the iOS app; nil when none does (the item is hidden).
    var revealTarget: String? {
        if isReady { return appPath }
        if hasIPA { return ipaPath }
        if hasIOSApp { return iosAppPath }
        return nil
    }
}

extension LibraryGame {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        titleID = try c.decode(String.self, forKey: .titleID)
        name = try c.decode(String.self, forKey: .name)
        appPath = try c.decodeIfPresent(String.self, forKey: .appPath) ?? ""
        ipaPath = try c.decodeIfPresent(String.self, forKey: .ipaPath) ?? ""
        archivePath = try c.decodeIfPresent(String.self, forKey: .archivePath) ?? ""
        lastTarget = BuildTarget.normalized(try c.decodeIfPresent(String.self, forKey: .lastTarget))
        inputs = try c.decodeIfPresent([String: [String]].self, forKey: .inputs) ?? [:]
        outputDirectory = try c.decodeIfPresent(String.self, forKey: .outputDirectory) ?? ""
        sourceFolder = try c.decodeIfPresent(String.self, forKey: .sourceFolder) ?? ""
        artworkPath = try c.decodeIfPresent(String.self, forKey: .artworkPath) ?? ""
        artwork = (try? c.decodeIfPresent(GameArtwork.self, forKey: .artwork)) ?? GameArtwork()
        launchOptions = try c.decodeIfPresent([String: String].self, forKey: .launchOptions) ?? [:]
        mods = try c.decodeIfPresent([String].self, forKey: .mods) ?? []
        iosAppPath = try c.decodeIfPresent(String.self, forKey: .iosAppPath) ?? ""
        installedDevice = try c.decodeIfPresent(String.self, forKey: .installedDevice) ?? ""
        toolsCommit = try c.decodeIfPresent(String.self, forKey: .toolsCommit) ?? ""
        titleNames = (try? c.decodeIfPresent([String: String].self, forKey: .titleNames)) ?? [:]
        customName = try c.decodeIfPresent(String.self, forKey: .customName) ?? ""
        lastPlayed = try c.decodeIfPresent(Date.self, forKey: .lastPlayed)
        defaultsApplied = try c.decodeIfPresent(Bool.self, forKey: .defaultsApplied) ?? true
    }
}

/// A folder in the game's mods folder: RomFS files that replace the game's own (DM_ROMFS_OVERLAY, hle_fs.c). The files are
/// found in <mod>/romfs, in an Atmosphère layout (<mod>/atmosphere/contents/<title ID>/romfs, <mod>/contents/<title ID>/romfs)
/// or in the folder itself. A mod with only exefs/ changes the game's code, which the rewriter does not take: listed, not usable.
struct GameMod: Identifiable, Equatable {
    let name: String
    let romfs: String?
    var id: String { name }
    var usable: Bool { romfs != nil }

    static func folder(for game: LibraryGame, library: String) -> URL {
        let root = library.isEmpty
            ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NS Port Builder")
            : URL(fileURLWithPath: library)
        return root.appendingPathComponent("mods").appendingPathComponent(game.titleID)
    }

    static func list(in folder: URL, titleID: String) -> [GameMod] {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        return names.compactMap { name in
            var dir: ObjCBool = false
            let mod = folder.appendingPathComponent(name)
            guard fm.fileExists(atPath: mod.path, isDirectory: &dir), dir.boolValue else { return nil }
            let candidates = ["romfs", "atmosphere/contents/\(titleID)/romfs", "contents/\(titleID)/romfs"].map { mod.appendingPathComponent($0).path }
            if let found = candidates.first(where: { fm.fileExists(atPath: $0) }) { return GameMod(name: name, romfs: found) }
            let top = ((try? fm.contentsOfDirectory(atPath: mod.path)) ?? []).filter { !$0.hasPrefix(".") }
            let codeOnly = top.allSatisfy { ["exefs", "atmosphere", "contents"].contains($0.lowercased()) } && !top.isEmpty
            return GameMod(name: name, romfs: codeOnly || top.isEmpty ? nil : mod.path)
        }
    }
}

extension LibraryGame {
    /// The value of a setting this launcher keeps itself (not a saved choice): the player's choice while the build still offers it,
    /// else the game's default. Saved choices are read through SavedChoices.
    func launchValue(_ s: LaunchSetting) -> String {
        launchOptions[s.env].flatMap { s.accepts($0) ? $0 : nil } ?? s.def
    }

    /// The launch overrides of the settings only this launcher has (Display mode); one at its unset value (Window) stays out.
    /// The rows of launcher.json are saved choices (SavedChoices) and are not passed: the app reads them itself, and a value here
    /// would override a choice made elsewhere.
    func launchEnvironment(_ settings: [LaunchSetting]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: settings.filter { !$0.storeBacked }.compactMap { s in
            let v = launchValue(s)
            return s.unsetValue == v ? nil : (s.env, v)
        })
    }

    /// DM_ROMFS_OVERLAY for the mods switched on that can be used, in the list's order: where two replace one file, the
    /// one higher in the list wins (the host looks in the folders in order).
    func modEnvironment(_ available: [GameMod]) -> [String: String] {
        let paths = available.filter { mods.contains($0.name) }.compactMap(\.romfs)
        return paths.isEmpty ? [:] : ["DM_ROMFS_OVERLAY": paths.joined(separator: ":")]
    }
}

final class GameLibrary: ObservableObject {
    /// The key of `LibraryGame.inputs` that holds a game folder (a Switch 2 game's base/, updates/, dlc/), read again on Build.
    static let folderInput = "folder"
    @Published private(set) var games: [LibraryGame] = []
    @Published var selectedID: UUID?
    @Published var error: String?
    /// The folders games are looked for in, in the order the player added them (LibraryRoots). The first wins when two hold a game.
    @Published private(set) var folders: [String] = []
    /// The first root: where a build goes when nothing else was chosen, and what the single-folder code reads.
    var folder: String { folders.first ?? "" }
    @Published private(set) var scanning = false
    /// The keys saved in Settings: their header_key finds packages whose name has no title ID (#1012). The launcher sets it.
    var keysFile: () -> String = { "" }
    private let file: URL
    let artworkDirectory: URL   // where this library's artwork lives: the store's, or a temporary one in tests
    private struct Snapshot: Codable {
        let games: [LibraryGame]
        let folder: String
        var folders: [String]? = nil   // absent in a library written before several roots (#992): `folder` is then the only one
    }

    /// `artwork` defaults to the store's folder for the app's own library, and to an `artwork` folder beside any other `file`: a library
    /// kept elsewhere (a test's) never reads, copies into or deletes from the player's artwork.
    init(file: URL? = nil, volumes: String = "/Volumes", artwork: URL? = nil) {
        artworkDirectory = artwork ?? file.map { $0.deletingLastPathComponent().appendingPathComponent("artwork", isDirectory: true) } ?? ArtworkStore.shared.directory
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NS Port Builder/library.json")
        if FileManager.default.fileExists(atPath: self.file.path) {
            do {
                let data = try Data(contentsOf: self.file)
                if let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
                    games = snapshot.games
                    folders = LibraryRoots.removing("", from: snapshot.folders ?? [snapshot.folder]).filter { !$0.isEmpty }
                } else { games = try JSONDecoder().decode([LibraryGame].self, from: data) }
            }
            catch { self.error = error.localizedDescription }
        }
        pruneMissingPaths(volumes: volumes)
        selectedID = games.first?.id
    }

    /// A path on an external volume (`/Volumes/<name>/...`) whose mount point is absent: the drive is not connected, so the file is
    /// not known to be gone and its path must stay.
    static func onUnmountedVolume(_ path: String, volumes: String = "/Volumes") -> Bool {
        VolumePath.onUnmounted(path, volumes: volumes)
    }

    /// Forgets a remembered Mac app, IPA or iOS app that is gone from disk, so nothing points at it. A file on a drive that is not
    /// connected is kept (the game is just not ready until the drive is back); one missing from a mounted volume is cleared. Saves only
    /// when something changed; run on load and after a scan, never from a view.
    func pruneMissingPaths(volumes: String = "/Volumes") {
        let fm = FileManager.default
        func gone(_ path: String, plist: Bool = false) -> Bool {
            !path.isEmpty && !Self.onUnmountedVolume(path, volumes: volumes) && !fm.fileExists(atPath: plist ? path + "/Info.plist" : path)
        }
        var changed = false
        for index in games.indices {
            let game = games[index]
            if gone(game.appPath) { games[index].appPath = ""; changed = true }
            if gone(game.ipaPath) { games[index].ipaPath = ""; changed = true }
            if gone(game.iosAppPath, plist: true) { games[index].iosAppPath = ""; games[index].installedDevice = ""; changed = true }
        }
        if changed { save() }
    }

    var selected: LibraryGame? { games.first { $0.id == selectedID } }

    /// False when the file could not be written: `error` says why.
    @discardableResult func save() -> Bool {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Snapshot(games: games, folder: folder, folders: folders)).write(to: file, options: .atomic)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    /// The elements in order, the first of each key kept: the same game or app found under two roots is one.
    static func firstOfEach<T>(_ items: [T], key: (T) -> String) -> [T] {
        var seen = Set<String>()
        return items.filter { seen.insert(key($0)).inserted }
    }

    /// Makes `url` the library's only root (the single-folder way, kept for the first choice and for tests).
    func setFolder(_ url: URL) {
        folders = LibraryRoots.adding(url.path, to: [])
        save()
        discover()
    }

    /// Adds a root unless it is already one (another spelling of the same folder counts as the same), then scans.
    func addFolder(_ url: URL) {
        folders = LibraryRoots.adding(url.path, to: folders)
        save()
        discover()
    }

    /// Forgets a root. The games found there stay in the library with their paths (they are not deleted, and a game on a drive that
    /// is not connected is not known to be gone), and its files are never touched.
    func removeFolder(_ path: String) {
        folders = LibraryRoots.removing(path, from: folders)
        save()
    }

    func rootState(_ path: String, volumes: String = "/Volumes") -> LibraryRoots.State {
        LibraryRoots.state(of: path, in: folders, volumes: volumes)
    }

    /// Where installed games are looked for besides the library folder (tests empty it).
    var applicationFolders = [URL(fileURLWithPath: "/Applications"),
                              FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]

    /// Games moved to /Applications or ~/Applications after a build (the CLI leaves the app
    /// beside the game, and people install it from there). Top level only, as the Finder
    /// puts them; the library folder comes first, so its copy wins over an installed one.
    static func installedApps(in dirs: [URL]) -> [URL] {
        let fm = FileManager.default
        return dirs.flatMap { dir in
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                .filter { (try? MacGameBundle.read($0)) != nil }
                .sorted { $0.path < $1.path }
        }
    }

    /// A bounded scan of build locations, never of a game's multi-GB contents.
    static func builtApps(in root: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                                             options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { return [] }
        let ignored = Set(["romfs", "extract", "node_modules", "xcode", "archive", "tools", "firmware", "keys", "venv", "shader", "msl", "pso", "bench", "harness", "runs"])
        var apps: [URL] = []
        var visited = 0
        while let url = enumerator.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            visited += 1
            if visited > 4000 { break }
            if url.pathExtension.lowercased() == "app" {
                enumerator.skipDescendants()
                if (try? MacGameBundle.read(url)) != nil { apps.append(url) }
            } else if enumerator.level >= 4 || ignored.contains(url.lastPathComponent.lowercased()) || url.lastPathComponent.hasSuffix("_build") || url.lastPathComponent.hasSuffix("_survey") || url.lastPathComponent.hasSuffix("-work") {
                enumerator.skipDescendants()
            }
        }
        return apps.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left == right ? $0.path < $1.path : left > right
        }
    }

    /// `headerKey` (the saved keys' header_key) also finds an NSP or NSZ whose name has no title ID, by its NCA headers (#1012).
    static func sourceGames(in root: URL, repo: String, headerKey: [UInt8]? = nil) -> [LibraryGame] {
        let ids = PackageTitleID.Resolver(headerKey: headerKey)
        if GameFolder.isDumpDirectory(root.path), case .success(let f) = GameFolder.scan(root.path) {
            var game = LibraryGame(titleID: f.titleIDHex, name: title(for: f.folder, repo: repo, titleID: f.titleIDHex))
            game.inputs = [GameLibrary.folderInput: [f.folder], "base": [f.basePath]]
            game.sourceFolder = f.folder
            game.outputDirectory = f.folder
            return [game]
        }
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { return [] }
        let packages = Set(["nsp", "xci", "nsz", "xcz"])
        var result: [String: LibraryGame] = [:]
        while let url = e.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let name = url.lastPathComponent.lowercased()
                // A game folder (a Switch 2 game's base/, updates/, dlc/, GameFolder.swift) is one game: its folder is its input,
                // and its 80,000 files are not walked.
                if GameFolder.isDirectCandidate(url.path) {
                    e.skipDescendants()
                    if case .success(let f) = GameFolder.scan(url.path), result[f.titleIDHex] == nil {
                        var game = LibraryGame(titleID: f.titleIDHex, name: title(for: f.folder, repo: repo, titleID: f.titleIDHex))
                        game.inputs = [GameLibrary.folderInput: [f.folder], "base": [f.basePath]]
                        game.sourceFolder = f.folder
                        game.outputDirectory = f.folder
                        result[f.titleIDHex] = game
                    }
                    continue
                }
                if e.level >= 4 || name.hasSuffix(".app") || name.hasSuffix("_build") || name.hasSuffix("-work") || name.hasSuffix("_survey") || ["romfs", "extract", "tools", "venv", "archive", "harness", "runs", "shader", "node_modules"].contains(name) { e.skipDescendants() }
                continue
            }
            // A NUP file is one game with its updates and DLC (GameFolder.readNUP): a folder that holds one was taken above
            if url.pathExtension.lowercased() == "nup", case .success(let f) = GameFolder.readNUP(url.path), f.hasTitleID, result[f.titleIDHex] == nil {
                var game = LibraryGame(titleID: f.titleIDHex, name: title(for: url.path, repo: repo, titleID: f.titleIDHex))
                game.inputs = [GameLibrary.folderInput: [url.path], "base": [url.path]]
                game.sourceFolder = f.folder
                game.outputDirectory = f.folder
                result[f.titleIDHex] = game
                continue
            }
            guard packages.contains(url.pathExtension.lowercased()),
                  let id = ids.titleID(url.path), id & 0xfff == 0 else { continue }
            let tid = String(format: "%016llX", id)
            guard result[tid] == nil else { continue }
            var game = LibraryGame(titleID: tid, name: title(for: url.path, repo: repo, titleID: tid))
            // A game's files are often split by kind: the base under "<game>/nsp本体/", the update and the DLC beside it.
            // The folder to scan is the one the player picks by hand — the game's own folder — so climb while the parent
            // still holds a package of this game's family (the base, its update, or one of its DLC), and stop at the scan
            // root or at a folder that holds no more of them (issue: an auto-scanned game found no update or DLC).
            let family = { (path: String) -> Bool in
                guard packages.contains((path as NSString).pathExtension.lowercased()),
                      let other = ids.titleID(path) else { return false }
                return other == id || (other >= id + 0x800 && other < id + 0x1000) || (other >= id + 0x1000 && other < id + 0x2000)
            }
            var gameRoot = url.deletingLastPathComponent()
            // The enumerator hands out resolved paths (/private/var/…) while the library folder may not be, so compare resolved.
            let rootReal = root.resolvingSymlinksInPath().path
            func inside(_ u: URL) -> String { u.resolvingSymlinksInPath().path }
            let skipDirs: Set<String> = ["romfs", "extract", "tools", "venv", "archive", "harness", "runs", "shader", "xcode"]
            func holdsFamily(_ folder: URL, except child: String) -> Bool {
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return false }
                if names.contains(where: { family(folder.appendingPathComponent($0).path) }) { return true }
                for name in names where name != child && !name.hasPrefix(".") {
                    let low = name.lowercased()
                    if skipDirs.contains(low) || low.hasSuffix("_build") || low.hasSuffix("_survey") { continue }
                    if let sub = try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(name).path),
                       sub.contains(where: { family(folder.appendingPathComponent(name).appendingPathComponent($0).path) }) { return true }
                }
                return false
            }
            while inside(gameRoot) != rootReal, inside(gameRoot).hasPrefix(rootReal) {
                let parent = gameRoot.deletingLastPathComponent()
                guard inside(parent).hasPrefix(rootReal),
                      holdsFamily(parent, except: gameRoot.lastPathComponent) else { break }
                gameRoot = parent
            }
            // Packages of this game anywhere in that folder, a few levels at most (what the build script itself scans).
            var found: [URL] = []
            if let walk = FileManager.default.enumerator(at: gameRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) {
                while let f = walk.nextObject() as? URL {
                    if (try? f.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                        let name = f.lastPathComponent.lowercased()
                        if walk.level >= 3 || ["romfs", "extract", "tools", "venv", "archive", "harness", "runs", "shader"].contains(name) { walk.skipDescendants() }
                        continue
                    }
                    if family(f.path) { found.append(f) }
                }
            }
            let familyOf = { (u: URL, lo: UInt64, hi: UInt64) -> Bool in
                guard let other = ids.titleID(u.path) else { return false }
                return other >= lo && other < hi
            }
            let isBase = { (u: URL) -> Bool in ids.titleID(u.path) == id }
            game.inputs["base"] = ([url] + found.filter(isBase))
                .sorted { TitleID.updateVersion($0.lastPathComponent) > TitleID.updateVersion($1.lastPathComponent) }
                .prefix(1).map(\.path)
            game.inputs["update"] = found.filter { familyOf($0, id + 0x800, id + 0x1000) }
                .sorted { TitleID.updateVersion($0.lastPathComponent) > TitleID.updateVersion($1.lastPathComponent) }.prefix(1).map(\.path)
            game.inputs["dlc"] = found.filter { familyOf($0, id + 0x1000, id + 0x2000) }.map(\.path).sorted()
            game.inputs["keys"] = [gameRoot.appendingPathComponent("prod.keys"), root.appendingPathComponent("keys/prod.keys"), root.appendingPathComponent("prod.keys"), gameRoot.appendingPathComponent("keys/prod.keys")]
                .filter { FileManager.default.fileExists(atPath: $0.path) }.prefix(1).map(\.path)
            game.sourceFolder = gameRoot.path
            game.outputDirectory = url.deletingLastPathComponent().path
            if let ipa = found.first(where: { $0.pathExtension.lowercased() == "ipa" }) { game.ipaPath = ipa.path }
            result[tid] = game
        }
        return result.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func discover(repo: String = RepoLayout.find()) {
        let roots = LibraryRoots.scannable(folders).map { URL(fileURLWithPath: $0) }   // a root on a drive that is not connected is skipped
        guard !roots.isEmpty, !scanning else { return }
        scanning = true
        let installed = applicationFolders, keys = keysFile()
        DispatchQueue.global(qos: .utility).async {
            let apps = Self.firstOfEach(roots.flatMap { Self.builtApps(in: $0) } + Self.installedApps(in: installed)) { $0.standardizedFileURL.path }
            let headerKey = PackageTitleID.headerKey(keysFile: keys)
            // Roots in their order: the first one that holds a game is its source, so the library does not depend on scan timing
            let sources = Self.firstOfEach(roots.flatMap { Self.sourceGames(in: $0, repo: repo, headerKey: headerKey) }) { $0.titleID }
            DispatchQueue.main.async {
                let previousSelection = self.selectedID
                for source in sources {
                    if var existing = self.games.first(where: { $0.titleID == source.titleID }) {
                        if existing.inputs["base", default: []].isEmpty { existing.inputs = source.inputs }
                        else {
                            // Slots the library has empty and the scan fills: an update or DLC added since, or a game
                            // recorded before the scan climbed out of a "nsp本体" folder (nothing was found beside it then).
                            for slot in ["update", "dlc", "keys"] where existing.inputs[slot, default: []].isEmpty {
                                existing.inputs[slot] = source.inputs[slot] ?? []
                            }
                            if existing.sourceFolder.isEmpty || (!source.sourceFolder.isEmpty && URL(fileURLWithPath: existing.sourceFolder).resolvingSymlinksInPath().path.hasPrefix(URL(fileURLWithPath: source.sourceFolder).resolvingSymlinksInPath().path + "/")) {
                                existing.sourceFolder = source.sourceFolder
                            }
                        }
                        if existing.ipaPath.isEmpty { existing.ipaPath = source.ipaPath }
                        // A name an older scan kept (a raw title ID, a size from the file name) gives way to the one the scan reads now
                        if existing.name != source.name, LibraryGame.needsBetterName(existing) { existing.name = source.name }
                        self.upsert(existing)
                    } else { self.upsert(source) }
                }
                for url in apps {
                    guard let info = try? MacGameBundle.read(url) else { continue }
                    if let existing = self.games.first(where: { $0.titleID == info.titleID }), existing.isReady { self.learnTitleNames(existing, from: info, at: url); continue }
                    _ = try? self.addApp(url)
                }
                self.pruneMissingPaths()
                self.selectedID = previousSelection ?? self.games.first?.id
                self.scanning = false
            }
        }
    }

    @discardableResult func addApp(_ url: URL) throws -> UUID {
        let app = try MacGameBundle.read(url)
        var game = games.first { $0.titleID == app.titleID } ?? LibraryGame(titleID: app.titleID, name: app.name)
        game.name = app.name
        if !app.titleNames.isEmpty { game.titleNames = app.titleNames }   // an older app has none: keep what TitleNameLookup read
        game.appPath = url.standardizedFileURL.path
        upsert(game)
        selectedID = game.id
        return game.id
    }

    @MainActor @discardableResult func rememberInputs(_ model: BuildStore) -> UUID? {
        guard !model.basePath.isEmpty else { return nil }
        let titleID = model.gameTitleID ?? URL(fileURLWithPath: model.basePath).standardizedFileURL.path
        // A base whose name has no title ID is the entry the scan found for it by its NCA headers (#1012), not a second one.
        func real(_ path: String?) -> String? { path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } }
        var game = games.first { $0.titleID == titleID } ?? games.first { model.gameTitleID == nil && real($0.inputs["base"]?.first) == real(model.basePath) }
            ?? LibraryGame(titleID: titleID, name: Self.title(for: model.gameFolder?.folder ?? model.basePath, repo: model.repo.path, titleID: titleID))
        game.inputs = Dictionary(uniqueKeysWithValues: model.slots.map { ($0.id, $0.paths) })
        // A game folder is kept as the folder: Build again reads it anew (LauncherView.configureBuild).
        if let folder = model.gameFolder { game.inputs[GameLibrary.folderInput] = [folder.scriptInput] }
        game.outputDirectory = model.outDir
        if !model.gameDir.isEmpty { game.sourceFolder = model.gameDir }
        game.lastTarget = model.target
        // An existing output is linked only after validating its metadata and executables.
        let dir = model.outDir.isEmpty ? model.inputFolder : model.outDir
        if let existing = MacAppOutput.existing(in: URL(fileURLWithPath: dir), titleID: model.gameTitleID, preferred: game.appPath) {
            game.appPath = existing.path
        }
        upsert(game)
        selectedID = game.id
        return game.id
    }

    func recordCompletedApp(path: String, commit: String = "", for id: UUID) {
        guard var game = games.first(where: { $0.id == id }),
              let app = try? MacGameBundle.read(URL(fileURLWithPath: path)),
              app.titleID == game.titleID || game.titleID.hasPrefix("/") else { return }
        // An entry keyed by its path (the base package's name carried no title ID) now learns the real one. If the
        // library already lists that game, this build replaces it: what the user set on the old entry carries over.
        if game.titleID != app.titleID, let old = games.first(where: { $0.id != id && $0.titleID == app.titleID }) {
            game.artworkPath = old.artworkPath
            game.artwork = old.artwork
            carryArtwork(of: old.id, to: id)
            game.launchOptions = old.launchOptions
            game.mods = old.mods
            game.iosAppPath = old.iosAppPath
            game.installedDevice = old.installedDevice
            game.ipaPath = old.ipaPath
            game.archivePath = old.archivePath
            if game.customName.isEmpty { game.customName = old.customName }   // the player's name for it (Manage > Rename)
            if game.titleNames.isEmpty { game.titleNames = old.titleNames }   // until the new app's own names replace them below
            games.removeAll { $0.id == old.id }
        }
        game.titleID = app.titleID
        game.appPath = path
        game.name = app.name
        if !app.titleNames.isEmpty { game.titleNames = app.titleNames }
        game.toolsCommit = commit   // empty for a checkout without git: nothing to compare, rather than an older build's commit
        upsert(game)
        selectedID = game.id
    }

    func recordCompletedIOS(archive: String, app: String, device: String = "", commit: String = "", for id: UUID) {
        guard var game = games.first(where: { $0.id == id }),
              FileManager.default.fileExists(atPath: app + "/Info.plist") else { return }
        // The shared app replaces an older build's single IPA: the file stays on disk, the library stops listing it
        game.ipaPath = ""
        if !archive.isEmpty { game.archivePath = archive }
        game.iosAppPath = app
        game.installedDevice = device
        game.toolsCommit = commit
        upsert(game)
        recordSharedAppInstalled(app: app, device: device)
    }

    /// Every game in the shared app's shell.json is inside `app` on `device` once the shared app is signed and installed there.
    func recordSharedAppInstalled(app: String, device: String) {
        guard !device.isEmpty,
              FileManager.default.fileExists(atPath: app + "/Info.plist"),
              let shell = ShellInstall.paths(ofApp: app) else { return }
        applySharedAppInstalled(titles: ShellLibrary.recordInstalled(root: shell.root), app: app, device: device)
    }

    private func applySharedAppInstalled(titles: Set<String>, app: String, device: String) {
        guard !device.isEmpty, !titles.isEmpty else { return }
        var changed = false
        for i in games.indices where titles.contains(games[i].titleID.uppercased()) {
            if games[i].iosAppPath != app || games[i].installedDevice != device || !games[i].ipaPath.isEmpty {
                games[i].ipaPath = ""
                games[i].iosAppPath = app
                games[i].installedDevice = device
                changed = true
            }
        }
        if changed { save() }
    }

    /// Restores the shared app's games from the last successful install receipt when `DmShell.app` is signed on disk
    /// (`embedded.mobileprovision` is present) and at least one receipt member still has recorded shared-app install provenance.
    func syncSharedApp(root: String) {
        let app = ShellInstall.appPath(root: root)
        guard FileManager.default.fileExists(atPath: app + "/" + AppSignature.profileName) else { return }
        let receipt = ShellLibrary.installedReceipt(root: root)
        guard !receipt.isEmpty,
              let device = games.first(where: {
                  receipt.contains($0.titleID.uppercased())
                      && !$0.installedDevice.isEmpty
                      && ShellInstall.paths(ofApp: $0.iosAppPath) != nil
              })?.installedDevice else { return }
        applySharedAppInstalled(titles: receipt, app: app, device: device)
    }

    /// Only a choice that differs from the game's default is kept, so a setting left at its default follows a later build's.
    func setLaunchOption(_ setting: LaunchSetting, _ value: String, for id: UUID) {
        guard var game = games.first(where: { $0.id == id }) else { return }
        game.launchOptions[setting.env] = setting.isDefault(value) ? nil : value
        upsert(game)
    }

    /// A mod switched on or off for one game.
    func setMod(_ name: String, on: Bool, for id: UUID) {
        guard var game = games.first(where: { $0.id == id }) else { return }
        game.mods.removeAll { $0 == name }
        if on { game.mods.append(name) }
        upsert(game)
    }

    /// The one-time move of the launch options an earlier version kept in the library file into each app's preferences domain
    /// (SavedChoices.migrate). The field stays decoded so an old library file loads; what is left in it is only what the store
    /// has no row for. Runs for every game that has options and an app with a settings list; a game without one waits.
    /// Then a game whose language was never picked gets the Mac's, once (SavedChoices.preselectLanguage).
    func migrateLaunchOptions() {
        var changed = false
        for i in games.indices where !games[i].launchOptions.isEmpty && !games[i].appPath.isEmpty {
            guard let settings = LaunchSetting.read(app: games[i].appPath) else { continue }
            let store = SavedChoices(app: games[i].appPath, titleID: games[i].titleID)
            for env in store.migrate(games[i].launchOptions, settings: settings) { games[i].launchOptions[env] = nil; changed = true }
        }
        applyPersonalDefaults()   // before the Mac's language fills what is still empty
        for game in games where !game.appPath.isEmpty {
            guard let settings = LaunchSetting.read(app: game.appPath) else { continue }
            SavedChoices(app: game.appPath, titleID: game.titleID).preselectLanguage(settings)
        }
        if changed { save() }
    }

    func resetLaunchOptions(for id: UUID) {
        guard var game = games.first(where: { $0.id == id }) else { return }
        game.launchOptions = [:]
        upsert(game)
    }

    private var migrating: Set<UUID> = []   // the games whose copy is being made in the background: setArtwork leaves their folder alone

    /// Moves a custom image that is not yet a copy of ours into the app's own folder (ArtworkImport), so the original can go. An
    /// image on a drive that is not connected, or that cannot be copied yet (a cloud file not downloaded, a damaged one), stays
    /// where it is and is tried again at the next launch. The original is never touched.
    func migrateArtwork(volumes: String = "/Volumes", completion: (() -> Void)? = nil) {
        let directory = artworkDirectory
        let copied = games.indices.filter { Self.isImported(games[$0].artworkPath, for: games[$0].id, in: directory) }   // a copy of the previous version
        copied.forEach { adoptArtwork(at: $0) }
        if !copied.isEmpty { save() }
        let pending = games.filter { game in
            !game.artworkPath.isEmpty && !Self.isImported(game.artworkPath, for: game.id, in: directory) && !Self.onUnmountedVolume(game.artworkPath, volumes: volumes)
        }.map { ($0.id, $0.artworkPath) }
        guard !pending.isEmpty else { completion?(); return }
        migrating.formUnion(pending.map(\.0))
        DispatchQueue.global(qos: .utility).async {
            let copies = pending.map { id, path in
                let copy = try? ArtworkImport.prepare(URL(fileURLWithPath: path), kind: .hero, into: ArtworkStore.customDirectory(for: id, in: directory))
                return (id, path, copy?.url.path ?? (FileManager.default.fileExists(atPath: path) ? path : ""))
            }
            DispatchQueue.main.async {
                var changed = false
                for (id, path, copy) in copies {
                    guard let index = self.games.firstIndex(where: { $0.id == id }), self.games[index].artworkPath == path else {
                        // Chosen again meanwhile, or the entry went (removed, or merged into a new build's): a copy nothing uses is not kept
                        if Self.isImported(copy, for: id, in: directory), !(self.games.first { $0.id == id }?.artwork.importedFiles.contains(URL(fileURLWithPath: copy).lastPathComponent) ?? false) {
                            try? FileManager.default.removeItem(atPath: copy)
                        }
                        continue
                    }
                    self.games[index].artworkPath = copy
                    if Self.isImported(copy, for: id, in: directory) { self.adoptArtwork(at: index) }
                    changed = true
                }
                self.migrating.subtract(pending.map(\.0))
                if changed { self.save() }
                completion?()
            }
        }
    }

    private func adoptArtwork(at index: Int) {
        games[index].artwork.hero = ArtworkChoice(source: .imported(URL(fileURLWithPath: games[index].artworkPath).lastPathComponent))
        games[index].artworkPath = ""
    }

    private static func isImported(_ path: String, for id: UUID, in directory: URL) -> Bool {
        path.hasPrefix(ArtworkStore.customDirectory(for: id, in: directory).path + "/")
    }

    /// An entry that takes over another's settings (recordCompletedApp) takes its images along: their folder is named for the entry's id.
    private func carryArtwork(of old: UUID, to id: UUID) {
        let from = ArtworkStore.customDirectory(for: old, in: artworkDirectory), to = ArtworkStore.customDirectory(for: id, in: artworkDirectory)
        guard FileManager.default.fileExists(atPath: from.path) else { return }
        try? FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
        for file in (try? FileManager.default.contentsOfDirectory(atPath: from.path)) ?? [] {
            let target = to.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: target.path) { try? FileManager.default.removeItem(at: from.appendingPathComponent(file)); continue }   // the same bytes, by its name
            try? FileManager.default.moveItem(at: from.appendingPathComponent(file), to: target)
        }
        if ((try? FileManager.default.contentsOfDirectory(atPath: from.path)) ?? []).isEmpty { try? FileManager.default.removeItem(at: from) }   // a file that could not move stays
    }

    /// Saves the game's slots, then removes the copies no slot uses any more. When the library cannot be written, it is left as it
    /// was, in memory and on disk, every copy is kept and the result is false.
    @discardableResult func setArtwork(_ artwork: GameArtwork, for id: UUID) -> Bool {
        guard var game = games.first(where: { $0.id == id }) else { return false }
        let before = games
        if artwork.hero != game.artwork.hero { game.artworkPath = "" }   // a hero chosen now replaces the path an earlier version kept
        game.artwork = artwork
        guard upsert(game) else { games = before; return false }
        // The copies no slot uses any more are ours, in this game's folder only. Not while a migration may have just written one there
        // that it adopts on the main queue next.
        guard !migrating.contains(id) else { return true }
        let directory = ArtworkStore.customDirectory(for: id, in: artworkDirectory)
        let kept = artwork.importedFiles
        let copies = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for file in copies where !kept.contains(file) && file.range(of: "^[0-9a-f]{64}\\.jpg$", options: .regularExpression) != nil {   // not a copy still being written
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
        return true
    }

    func remove(_ id: UUID) {
        games.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: ArtworkStore.customDirectory(for: id, in: artworkDirectory))   // our copies, never the game's files
        if selectedID == id { selectedID = games.first?.id }
        save()
    }

    @discardableResult func upsert(_ game: LibraryGame) -> Bool {   // internal: LibraryGame+Names.swift
        if let index = games.firstIndex(where: { $0.id == game.id }) { games[index] = game }
        else { games.append(game) }
        return save()
    }

    static func title(for path: String, repo: String, titleID: String) -> String {
        if let text = try? String(contentsOfFile: EngineLayout.root(repo) + "/dm/games/" + titleID + "/game.tsv", encoding: .utf8),
           let row = text.split(separator: "\n").first(where: { $0.hasPrefix("name\t") }) {
            return String(row.dropFirst(5))
        }
        return LibraryGame.cleanedName(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
    }
}
