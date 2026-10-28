import AppKit
import SwiftUI

/// Only paths and presentation metadata live here. Game data stays on its original drive.
struct LibraryGame: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var titleID: String
    var name: String
    var appPath = ""
    var ipaPath = ""
    var archivePath = ""
    var lastTarget = "ios"
    var inputs: [String: [String]] = [:]
    var outputDirectory = ""
    var artworkPath = ""
    var launchOptions: [String: String] = [:]
    var mods: [String] = []   // the mods (folder names in the game's mods folder) switched on
    var iosAppPath = ""
    var installedDevice = ""
    /// The repository checkout's commit the last finished build used (ToolsAge); empty for a build from before it was recorded.
    var toolsCommit = ""

    var isReady: Bool {
        guard let app = try? MacGameBundle.read(URL(fileURLWithPath: appPath)) else { return false }
        return app.titleID == titleID
    }

    /// Signed and installed on a paired device (installedDevice is its UDID): Play starts it there.
    var onDevice: Bool { !installedDevice.isEmpty && FileManager.default.fileExists(atPath: iosAppPath + "/Info.plist") }

    var hasIOSBuild: Bool { hasIPA || hasIOSApp }
    var hasIPA: Bool { !ipaPath.isEmpty && FileManager.default.fileExists(atPath: ipaPath) }
    var hasIOSApp: Bool { !iosAppPath.isEmpty && FileManager.default.fileExists(atPath: iosAppPath + "/Info.plist") }

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
        lastTarget = try c.decodeIfPresent(String.self, forKey: .lastTarget) ?? "ios"
        inputs = try c.decodeIfPresent([String: [String]].self, forKey: .inputs) ?? [:]
        outputDirectory = try c.decodeIfPresent(String.self, forKey: .outputDirectory) ?? ""
        artworkPath = try c.decodeIfPresent(String.self, forKey: .artworkPath) ?? ""
        launchOptions = try c.decodeIfPresent([String: String].self, forKey: .launchOptions) ?? [:]
        mods = try c.decodeIfPresent([String].self, forKey: .mods) ?? []
        iosAppPath = try c.decodeIfPresent(String.self, forKey: .iosAppPath) ?? ""
        installedDevice = try c.decodeIfPresent(String.self, forKey: .installedDevice) ?? ""
        toolsCommit = try c.decodeIfPresent(String.self, forKey: .toolsCommit) ?? ""
    }
}

/// One row of the app's `dm/launcher.json` (dm/games/settings.py), the list the iPhone launcher shows
/// (dm/ios/Sources/LauncherSettings.swift). Each sets an environment variable the game reads at start.
struct LaunchSetting: Decodable, Identifiable {
    let env, kind, label, note, def: String
    let section: String?
    let options: [[String]]?   // choice: [value, label]
    let min, max, step: Double?   // range
    let on, off: String?   // toggle: the values the variable takes
    /// "basic" for a setting shown first (settings.tsv's level column, seedds/nxnative#399); without it, `basicByDefault` decides.
    var level: String? = nil
    /// The 3D views' base size the setting scales, docked and handheld ([width, height]); the render scale's row shows pixels with it.
    var base: [String: [Int]]? = nil
    /// `<VAR>=<value>` (schema 1, optional): the row is a sub-setting, shown only while the row that sets <VAR> has that value.
    var needs: String? = nil
    /// The value that leaves the variable unset (DM_FULLSCREEN is on when it is set at all).
    var unsetValue: String? = nil
    /// A setting this launcher adds itself (launcher.json has no row for it) is not a saved choice: the store has no rule for it.
    var storeBacked: Bool { unsetValue == nil }
    var id: String { env }
    var sectionTitle: String { section ?? "Game" }
    /// The rows the sheet shows first, as seedds/nxnative#374 groups them; the rest are under Advanced settings.
    static let basicByDefault: Set = ["DM_FPS_TARGET", "DM_RENDER_SCALE", "DM_FULLSCREEN", "DM_OPMODE", "DM_LANG", "DM_RUMBLE"]
    var isBasic: Bool { level.map { $0 == "basic" } ?? Self.basicByDefault.contains(env) }
    var onValue: String { on ?? "1" }
    var offValue: String { off ?? "0" }
    func isDefault(_ v: String) -> Bool {   // a range compares as numbers (a slider writes 1.00 for 1.0)
        kind == "range" ? abs((Double(v) ?? .nan) - (Double(def) ?? .nan)) < 1e-6 : v == def
    }
    func accepts(_ v: String) -> Bool {   // a saved choice the build still offers
        switch kind {
        case "choice": return options?.contains { $0.first == v } ?? false
        case "range":   // as dm/mac/launcher.c: no leading space, no hex, no NaN
            guard !v.isEmpty, !(v.first?.isWhitespace ?? true), !v.contains("x"), !v.contains("X"),
                  let n = Double(v), n.isFinite, let lo = min, let hi = max else { return false }
            return n >= lo && n <= hi
        case "toggle": return v == onValue || v == offValue
        default: return true
        }
    }
    enum CodingKeys: String, CodingKey { case env, kind, label, note, def = "default", section, options, min, max, step, on, off, level, base, needs }

    /// The settings a Mac app was packed with; nil for an app packed before they were (see LaunchList for the schema).
    static func read(app: String) -> [LaunchSetting]? {
        let url = URL(fileURLWithPath: app).appendingPathComponent("Contents/Resources/dm/launcher.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return LaunchList.parse(data)?.settings
    }

    /// The app's settings as the Mac shows them: the Mac-only Display mode added when the list has none (the host reads
    /// DM_FULLSCREEN in front_mac.m; a list from settings.tsv will carry it as a platform:mac row), and the render scale's
    /// base size from the game's profile in the repository when the list does not carry it (render_base).
    static func forMac(app: String, titleID: String, repo: String, labels: (String) -> String) -> [LaunchSetting]? {
        guard var list = read(app: app) else { return nil }
        if !list.contains(where: { $0.env == "DM_FULLSCREEN" }) {
            let display = LaunchSetting(env: "DM_FULLSCREEN", kind: "choice", label: labels("launch.display"), note: "", def: "",
                                        section: "Game", options: [["", labels("launch.display.window")], ["1", labels("launch.display.fullscreen")]],
                                        min: nil, max: nil, step: nil, on: nil, off: nil, unsetValue: "")
            list.insert(display, at: (list.firstIndex { $0.env == "DM_RENDER_SCALE" }).map { $0 + 1 } ?? 0)
        }
        if let i = list.firstIndex(where: { $0.env == "DM_RENDER_SCALE" && $0.base == nil }), let base = renderBase(titleID: titleID, repo: repo) {
            list[i].base = base
        }
        return list
    }

    /// render_base in the game's profile ("1600x900 1280x720": docked, then handheld).
    static func renderBase(titleID: String, repo: String) -> [String: [Int]]? {
        let path = repo + "/dm/games/" + titleID + "/game.tsv"
        guard !repo.isEmpty, let text = try? String(contentsOfFile: path, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("render_base\t") }) else { return nil }
        let sizes = line.dropFirst("render_base\t".count).split(separator: " ").map { $0.split(separator: "x").compactMap { Int($0) } }
        guard sizes.count == 2, sizes.allSatisfy({ $0.count == 2 }) else { return nil }
        return ["docked": sizes[0], "handheld": sizes[1]]
    }

    /// The render scale as pixels: the base size of the console mode chosen (DM_OPMODE: 1 docked, 0 handheld) times the scale.
    func pixels(scale: Double, docked: Bool) -> String? {
        guard let size = base?[docked ? "docked" : "handheld"], size.count == 2 else { return nil }
        return "\(Int((Double(size[0]) * scale).rounded()))×\(Int((Double(size[1]) * scale).rounded()))"
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

struct MacGameBundle {
    let titleID: String
    let name: String

    enum Invalid: LocalizedError {
        case notGame
        var errorDescription: String? { "Choose a complete nxnative Mac game app built by the NSP pipeline." }
    }

    static func read(_ url: URL) throws -> MacGameBundle {
        guard url.pathExtension.lowercased() == "app",
              let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let rawID = info["DMTitleID"] as? String,
              rawID.range(of: "^[0-9A-Fa-f]{16}$", options: .regularExpression) != nil,
              let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty, executable != ".", executable != "..", !executable.contains("/"),
              FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("Contents/MacOS/" + executable).path),
              FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("Contents/MacOS/dmhost").path)
        else { throw Invalid.notGame }
        return MacGameBundle(titleID: rawID.uppercased(),
                             name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent)
    }
}

final class GameLibrary: ObservableObject {
    @Published private(set) var games: [LibraryGame] = []
    @Published var selectedID: UUID?
    @Published var error: String?
    @Published private(set) var folder = ""
    @Published private(set) var scanning = false
    private let file: URL
    private struct Snapshot: Codable {
        let games: [LibraryGame]
        let folder: String
    }

    init(file: URL? = nil, volumes: String = "/Volumes") {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NS Port Builder/library.json")
        if FileManager.default.fileExists(atPath: self.file.path) {
            do {
                let data = try Data(contentsOf: self.file)
                if let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
                    games = snapshot.games
                    folder = snapshot.folder
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
        let prefix = volumes.hasSuffix("/") ? volumes : volumes + "/"
        guard path.hasPrefix(prefix), let name = path.dropFirst(prefix.count).split(separator: "/").first else { return false }
        return !FileManager.default.fileExists(atPath: prefix + name)
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

    func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Snapshot(games: games, folder: folder)).write(to: file, options: .atomic)
        } catch { self.error = error.localizedDescription }
    }

    func setFolder(_ url: URL) {
        folder = url.standardizedFileURL.path
        save()
        discover()
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

    static func sourceGames(in root: URL, repo: String) -> [LibraryGame] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { return [] }
        var result: [String: LibraryGame] = [:]
        while let url = e.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let name = url.lastPathComponent.lowercased()
                if e.level >= 4 || name.hasSuffix(".app") || name.hasSuffix("_build") || name.hasSuffix("-work") || name.hasSuffix("_survey") || ["romfs", "extract", "tools", "venv", "archive", "harness", "runs", "shader", "node_modules"].contains(name) { e.skipDescendants() }
                continue
            }
            guard ["nsp", "xci", "nsz", "xcz"].contains(url.pathExtension.lowercased()),
                  let id = BuildModel.titleID(url.lastPathComponent), id & 0xfff == 0 else { continue }
            let tid = String(format: "%016llX", id)
            guard result[tid] == nil else { continue }
            var game = LibraryGame(titleID: tid, name: title(for: url.path, repo: repo, titleID: tid))
            let parent = url.deletingLastPathComponent()
            let files = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
            game.inputs["base"] = [url.path]
            game.inputs["update"] = files.filter { BuildModel.titleID($0.lastPathComponent) == id + 0x800 && ["nsp", "xci", "nsz", "xcz"].contains($0.pathExtension.lowercased()) }
                .sorted { BuildModel.updateVersion($0.lastPathComponent) > BuildModel.updateVersion($1.lastPathComponent) }.prefix(1).map(\.path)
            game.inputs["dlc"] = files.filter {
                guard let other = BuildModel.titleID($0.lastPathComponent) else { return false }
                return other >= id + 0x1000 && other < id + 0x2000 && ["nsp", "nsz"].contains($0.pathExtension.lowercased())
            }.map(\.path)
            game.inputs["keys"] = [parent.appendingPathComponent("prod.keys"), root.appendingPathComponent("keys/prod.keys"), root.appendingPathComponent("prod.keys")]
                .filter { FileManager.default.fileExists(atPath: $0.path) }.prefix(1).map(\.path)
            game.outputDirectory = parent.path
            if let ipa = files.first(where: { $0.pathExtension.lowercased() == "ipa" }) { game.ipaPath = ipa.path }
            result[tid] = game
        }
        return result.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func discover(repo: String = BuildModel.findRepo()) {
        guard !folder.isEmpty, !scanning else { return }
        scanning = true
        let root = URL(fileURLWithPath: folder), installed = applicationFolders
        DispatchQueue.global(qos: .utility).async {
            let apps = Self.builtApps(in: root) + Self.installedApps(in: installed)
            let sources = Self.sourceGames(in: root, repo: repo)
            DispatchQueue.main.async {
                let previousSelection = self.selectedID
                for source in sources {
                    if var existing = self.games.first(where: { $0.titleID == source.titleID }) {
                        if existing.inputs["base", default: []].isEmpty { existing.inputs = source.inputs }
                        if existing.ipaPath.isEmpty { existing.ipaPath = source.ipaPath }
                        self.upsert(existing)
                    } else { self.upsert(source) }
                }
                for url in apps {
                    guard let info = try? MacGameBundle.read(url) else { continue }
                    if let existing = self.games.first(where: { $0.titleID == info.titleID }), existing.isReady { continue }
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
        game.appPath = url.standardizedFileURL.path
        upsert(game)
        selectedID = game.id
        return game.id
    }

    @discardableResult func rememberInputs(_ model: BuildModel) -> UUID? {
        guard !model.basePath.isEmpty else { return nil }
        let titleID = BuildModel.titleID(model.basePath).map { String(format: "%016llX", $0) }
            ?? URL(fileURLWithPath: model.basePath).standardizedFileURL.path
        var game = games.first { $0.titleID == titleID } ?? LibraryGame(titleID: titleID, name: Self.title(for: model.basePath, repo: model.repoPath, titleID: titleID))
        game.inputs = Dictionary(uniqueKeysWithValues: model.slots.map { ($0.id, $0.paths) })
        game.outputDirectory = model.outDir
        game.lastTarget = model.target
        // An existing output is linked only after validating its metadata and executables.
        let dir = model.outDir.isEmpty ? URL(fileURLWithPath: model.basePath).deletingLastPathComponent().path : model.outDir
        let expected = URL(fileURLWithPath: dir).appendingPathComponent(titleID + ".app")
        if let app = try? MacGameBundle.read(expected), app.titleID == titleID { game.appPath = expected.path }
        upsert(game)
        selectedID = game.id
        return game.id
    }

    func recordCompletedApp(path: String, commit: String = "", for id: UUID) {
        guard var game = games.first(where: { $0.id == id }),
              let app = try? MacGameBundle.read(URL(fileURLWithPath: path)),
              app.titleID == game.titleID || game.titleID.hasPrefix("/") else { return }
        game.titleID = app.titleID
        game.appPath = path
        game.name = app.name
        game.toolsCommit = commit   // empty for a checkout without git: nothing to compare, rather than an older build's commit
        upsert(game)
    }

    func recordCompletedIOS(ipa: String, archive: String, app: String = "", device: String = "", commit: String = "", for id: UUID) {
        guard var game = games.first(where: { $0.id == id }),
              FileManager.default.fileExists(atPath: ipa) || FileManager.default.fileExists(atPath: app + "/Info.plist") else { return }
        // What this build made; an earlier build's IPA or installed app stays when this one made none
        if !ipa.isEmpty { game.ipaPath = ipa }
        if !archive.isEmpty { game.archivePath = archive }
        if !app.isEmpty { game.iosAppPath = app; game.installedDevice = device }
        game.toolsCommit = commit
        upsert(game)
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
    func migrateLaunchOptions() {
        var changed = false
        for i in games.indices where !games[i].launchOptions.isEmpty && !games[i].appPath.isEmpty {
            guard let settings = LaunchSetting.read(app: games[i].appPath) else { continue }
            let store = SavedChoices(app: games[i].appPath, titleID: games[i].titleID)
            for env in store.migrate(games[i].launchOptions, settings: settings) { games[i].launchOptions[env] = nil; changed = true }
        }
        if changed { save() }
    }

    func resetLaunchOptions(for id: UUID) {
        guard var game = games.first(where: { $0.id == id }) else { return }
        game.launchOptions = [:]
        upsert(game)
    }

    func setArtwork(_ path: String, for id: UUID) {
        guard var game = games.first(where: { $0.id == id }) else { return }
        game.artworkPath = path
        upsert(game)
    }

    func remove(_ id: UUID) {
        games.removeAll { $0.id == id }
        if selectedID == id { selectedID = games.first?.id }
        save()
    }

    private func upsert(_ game: LibraryGame) {
        if let index = games.firstIndex(where: { $0.id == game.id }) { games[index] = game }
        else { games.append(game) }
        save()
    }

    static func title(for path: String, repo: String, titleID: String) -> String {
        if let text = try? String(contentsOfFile: repo + "/dm/games/" + titleID + "/game.tsv", encoding: .utf8),
           let row = text.split(separator: "\n").first(where: { $0.hasPrefix("name\t") }) {
            return String(row.dropFirst(5))
        }
        let filename = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let name = filename.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? filename : name
    }

    /// Prefer a user's own image, then the game's eShop key art (ArtworkStore), then an existing repository
    /// gameplay screenshot, then the app icon.
    static func artwork(for game: LibraryGame, repo: String, banners: URL = ArtworkStore.shared.directory) -> NSImage? {
        if !game.artworkPath.isEmpty, let image = NSImage(contentsOfFile: game.artworkPath) { return image }
        if let url = ArtworkStore.cachedBanner(game.titleID, in: banners), let image = NSImage(contentsOf: url) { return image }
        func normalized(_ s: String) -> String {
            s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .filter { $0.isLetter || $0.isNumber }
        }
        let name = normalized(game.name)
        let images = URL(fileURLWithPath: repo).appendingPathComponent("docs/images")
        let files = (try? FileManager.default.contentsOfDirectory(at: images, includingPropertiesForKeys: nil)) ?? []
        let matches = files.filter {
            ["jpg", "jpeg", "png", "webp"].contains($0.pathExtension.lowercased()) && name.hasSuffix(normalized($0.deletingPathExtension().lastPathComponent))
        }.sorted { $0.lastPathComponent.count > $1.lastPathComponent.count }
        if let url = matches.first, let image = NSImage(contentsOf: url) { return image }
        if !game.appPath.isEmpty, let icon = NSImage(contentsOfFile: game.appPath + "/Contents/Resources/AppIcon.icns") { return icon }
        // Extraction icons are small; they are a fallback, never presented as high-resolution artwork.
        return nil
    }
}
