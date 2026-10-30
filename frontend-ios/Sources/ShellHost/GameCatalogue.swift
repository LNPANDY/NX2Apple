import Foundation
import os
import ShellUI

private let logger = Logger(subsystem: "dev.nx2apple.shell", category: "catalogue")

/// What the shell and the app it runs in are, for the checks that need an app version: the shader chain it was built
/// with and the OS it runs on. A nil chain skips the chain check (the demo has no engine).
public struct HostEnvironment: Equatable, Sendable {
    public var chain: String?
    public var osVersion: OperatingSystemVersion
    public init(chain: String? = nil, osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) {
        self.chain = chain
        self.osVersion = osVersion
    }
    public static func == (a: Self, b: Self) -> Bool {
        a.chain == b.chain && a.osVersion.majorVersion == b.osVersion.majorVersion
            && a.osVersion.minorVersion == b.osVersion.minorVersion && a.osVersion.patchVersion == b.osVersion.patchVersion
    }
}

/// One folder under `Games/`, read: what its files say, or why they could not be read.
public struct CatalogueEntry: Equatable, Sendable, Identifiable {
    public var id: String
    public var directory: URL
    public var manifest: GameManifest?
    public var profile: LauncherProfile?
    public var bannerURL: URL?
    public var iconURL: URL?
    /// Set when the bundle cannot run at all, whatever the app or the data: the broken state.
    public var problem: GameProblem?

    /// The name from a manifest that could not be fully read, when it still has one.
    public var readableName: String?

    /// Never the bare title ID: an unreadable bundle is "Unknown game". The ID is shown only in the How to fix sheet.
    public var title: String { manifest?.name ?? readableName ?? hostText("Unknown game") }
    public var frameworkURL: URL? { manifest.map { directory.appendingPathComponent($0.framework, isDirectory: true) } }
}

/// Discovers games from a folder of bundles: `Games/<title ID>/` with `game.manifest.json`, `launcher.json`, the
/// manifest's `<name>.framework` and optional `banner.<ext>` and `icon.<ext>` pictures. Pure reads, no state.
public enum GameCatalogue {
    public static let imageExtensions = ["png", "jpg", "jpeg", "heic", "webp"]

    public static func scan(root: URL, fileManager fm: FileManager = .default) -> [CatalogueEntry] {
        let names = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        var entries: [CatalogueEntry] = []
        for name in names {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            entries.append(read(directory: dir, fileManager: fm))
        }
        return entries.sorted { ($0.manifest?.name ?? "\u{10FFFF}\($0.id)").localizedCaseInsensitiveCompare($1.manifest?.name ?? "\u{10FFFF}\($1.id)") == .orderedAscending }
    }

    public static func read(directory dir: URL, fileManager fm: FileManager = .default) -> CatalogueEntry {
        let id = dir.lastPathComponent
        var entry = CatalogueEntry(id: id, directory: dir, bannerURL: image(named: "banner", in: dir, fm), iconURL: image(named: "icon", in: dir, fm))
        entry.readableName = lenientName(in: dir.appendingPathComponent("game.manifest.json"), fm)
        do {
            guard let data = fm.contents(atPath: dir.appendingPathComponent("game.manifest.json").path) else {
                throw GameProblem(cause: .manifestMissing, reason: hostText("Game manifest missing"), detail: hostText("This game's folder has no game.manifest.json."))
            }
            let manifest = try GameManifest.parse(data)
            entry.manifest = manifest
            guard manifest.titleID == id else {
                throw GameProblem(cause: .filesDamaged, reason: hostText("Game files damaged"), detail: hostText("The folder is named \(id) but the manifest says \(manifest.titleID)."))
            }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.appendingPathComponent(manifest.framework).path, isDirectory: &isDir), isDir.boolValue else {
                throw GameProblem(cause: .codeMissing, reason: hostText("Game code missing"), detail: hostText("\(manifest.framework) is not in this game's folder. Install the game again."))
            }
            let direct = dir.appendingPathComponent("launcher.json")
            let inFramework = dir.appendingPathComponent(manifest.framework).appendingPathComponent(manifest.launcher)
            guard let launcherData = fm.contents(atPath: direct.path) ?? fm.contents(atPath: inFramework.path) else {
                throw GameProblem(cause: .settingsMissing, reason: hostText("Settings list missing"), detail: hostText("This game has no launcher.json."))
            }
            let profile = try LauncherProfile.parse(launcherData)
            guard profile.game == manifest.titleID else {
                throw GameProblem(cause: .filesDamaged, reason: hostText("Game files damaged"), detail: hostText("launcher.json is for \(profile.game), the manifest for \(manifest.titleID)."))
            }
            entry.profile = profile
        } catch let problem as GameProblem {
            entry.problem = problem
        } catch {
            entry.problem = GameProblem(cause: .filesDamaged, reason: hostText("Game files damaged"), detail: error.localizedDescription)
        }
        if let problem = entry.problem {
            // The technical message is for the log and the Details of the How to fix sheet, not for the hero.
            logger.error("\(id, privacy: .public): \(problem.reason, privacy: .public): \(problem.detail, privacy: .public)")
        }
        return entry
    }

    /// The `name` of a manifest that fails validation, when the file is still JSON with a name in it.
    private static func lenientName(in url: URL, _ fm: FileManager) -> String? {
        guard let data = fm.contents(atPath: url.path),
              let name = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["name"] as? String else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func image(named base: String, in dir: URL, _ fm: FileManager) -> URL? {
        imageExtensions.map { dir.appendingPathComponent("\(base).\($0)") }.first { fm.fileExists(atPath: $0.path) }
    }
}

/// Where a game's data was found.
public enum DataSource: Equatable, Sendable {
    /// The app's own `Documents/games/<title ID>/`.
    case app
    /// A folder the player picked, through a bookmark.
    case picked
}

public struct DataResolution: Equatable, Sendable {
    /// The folder holding `romfs.img` or `romfs/<marker>`, or a picked `romfs.img`'s folder.
    public var url: URL?
    public var source: DataSource?
    /// A bookmark exists but no longer resolves (the app is signed differently now).
    public var pickedIsStale: Bool
    public var found: Bool { url != nil }
    public static let missing = DataResolution(url: nil, source: nil, pickedIsStale: false)
}

/// The same order as the per-game app's `romfs_locate` (dm/ios/Sources/main.m): the picked location first, then the
/// app's `Documents/games/<title ID>/`, each accepted only when it holds the game's image or marker.
public enum DataLocator {
    public static func locate(manifest: GameManifest, picked: BookmarkResolution, appFolder: URL, fileManager fm: FileManager = .default) -> DataResolution {
        var result = DataResolution.missing
        switch picked {
        case .stale: result.pickedIsStale = true
        case .url(let url):
            if let dir = holder(of: url, manifest: manifest, fm) { result.url = dir; result.source = .picked; return result }
        case .none: break
        }
        if let dir = holder(of: appFolder, manifest: manifest, fm) { result.url = dir; result.source = .app }
        return result
    }

    /// The folder in `url` (or `url` itself) that holds the game: an image, or a tree with the marker.
    static func holder(of url: URL, manifest: GameManifest, _ fm: FileManager) -> URL? {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue { return url.pathExtension == "img" && isNonEmpty(url, fm) ? url.deletingLastPathComponent() : nil }
        if isNonEmpty(url.appendingPathComponent("romfs.img"), fm) { return url }
        for tree in [url, url.appendingPathComponent("romfs", isDirectory: true)]
        where fm.fileExists(atPath: tree.appendingPathComponent(manifest.romfsMarker).path) { return url }
        return nil
    }

    private static func isNonEmpty(_ url: URL, _ fm: FileManager) -> Bool {
        ((try? fm.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0 > 0
    }
}

/// Derives the state a tile shows from what is present: a bundle that cannot run is broken with its reason, a game
/// built for another chain or a newer OS needs an app update, a game without reachable data needs game data.
public enum GameStateResolver {
    public static func state(for entry: CatalogueEntry, data: DataResolution, environment: HostEnvironment) -> GameState {
        if let problem = entry.problem { return problem.state }
        guard let manifest = entry.manifest else { return GameProblem(cause: .manifestMissing, reason: hostText("Game manifest missing")).state }
        if let chain = environment.chain, chain != manifest.chain { return .needsAppUpdate }
        if let min = manifest.minOSVersion, !isVersion(environment.osVersion, atLeast: min) { return .needsAppUpdate }
        return data.found ? .playable : .needsGameData
    }
}
