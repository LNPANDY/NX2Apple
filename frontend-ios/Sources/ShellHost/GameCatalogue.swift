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
    /// The game's framework folder: inside `directory` for a `Games/<title ID>/` bundle, `directory` itself for an
    /// embedded `<Name>.framework`. Nil while the manifest could not be read.
    public var frameworkURL: URL?
    /// Set when the unsigned shared IPA externalized this framework's `msl/` shader tree alongside game data (#947).
    public var requiresExternalShaders: Bool = false
}

/// Marker written last inside `Documents/Frameworks/.staging-<ID>-<token>/.ready` once every file of a hot-pushed
/// `DmGame<ID>.framework` has landed on the device. `GameCatalogue.promoteStagedFrameworks` leaves a staging folder
/// untouched until `.ready` is valid and the staged framework's regular file count and byte total match.
public struct HotFrameworkReady: Codable, Equatable, Sendable {
    public static let fileName = ".ready"
    public static let stagingPrefix = ".staging-"
    public static let discardPrefix = ".discarded-"
    public static let currentSchema = 1

    public var schema: Int
    public var titleID: String
    public var files: Int
    public var bytes: Int64

    public init(schema: Int = Self.currentSchema, titleID: String, files: Int, bytes: Int64) {
        self.schema = schema
        self.titleID = titleID
        self.files = files
        self.bytes = bytes
    }
}

/// Discovers games from a folder of bundles: `Games/<title ID>/` with `game.manifest.json`, `launcher.json`, the
/// manifest's `<name>.framework` and optional `banner.<ext>` and `icon.<ext>` pictures, or, in the shell app, the
/// embedded `<Name>.framework` folders that hold the manifest and everything else themselves. Pure reads, no state
/// except atomic staging promotion inside `hotRoot` (`Documents/Frameworks`).
public enum GameCatalogue {
    public static let imageExtensions = ["png", "jpg", "jpeg", "heic", "webp"]

    /// Counts regular files and total bytes inside `framework` (skipping Finder `.DS_Store` and AppleDouble `._*` metadata),
    /// returning nil on directory absence or integer overflow. Shared by staging verification and tests.
    public static func frameworkFootprint(at framework: URL, fileManager fm: FileManager = .default) -> (files: Int, bytes: Int64)? {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: framework.path, isDirectory: &isDir), isDir.boolValue,
              let enumerator = fm.enumerator(atPath: framework.path) else { return nil }
        var files = 0
        var bytes: Int64 = 0
        for case let rel as String in enumerator {
            let name = (rel as NSString).lastPathComponent
            if name == ".DS_Store" || name.hasPrefix("._") { continue }
            let full = framework.appendingPathComponent(rel).path
            guard let attrs = try? fm.attributesOfItem(atPath: full),
                  let type = attrs[.type] as? FileAttributeType else { return nil }
            if type == .typeDirectory { continue }
            guard type == .typeRegular, let size = (attrs[.size] as? NSNumber)?.int64Value, size >= 0 else { return nil }
            if Int64.max - bytes < size { return nil }
            files += 1
            bytes += size
        }
        return (files, bytes)
    }

    /// Promotes completed `.staging-*` framework folders inside `hotRoot` into `hotRoot/DmGame<ID>.framework` atomically.
    /// Staging folders without `.ready` that are newer than `staleAge` stay untouched (a transfer may still be in flight).
    public static func promoteStagedFrameworks(in hotRoot: URL, now: Date = Date(), staleAge: TimeInterval = 3600,
                                               fileManager fm: FileManager = .default) {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: hotRoot.path, isDirectory: &isDir), isDir.boolValue else { return }
        let items = (try? fm.contentsOfDirectory(atPath: hotRoot.path)) ?? []
        for item in items where item.hasPrefix(HotFrameworkReady.discardPrefix) {
            try? fm.removeItem(at: hotRoot.appendingPathComponent(item))
        }
        let stagings = items.filter { $0.hasPrefix(HotFrameworkReady.stagingPrefix) }.map { name -> (url: URL, mtime: Date) in
            let url = hotRoot.appendingPathComponent(name, isDirectory: true)
            let mtime = ((try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? .distantPast
            return (url, mtime)
        }.sorted { ($0.mtime, $0.url.lastPathComponent) < ($1.mtime, $1.url.lastPathComponent) }

        var promotedTitles = Set<String>()
        var incompleteStagings: [(url: URL, mtime: Date, name: String)] = []

        for staging in stagings {
            let readyURL = staging.url.appendingPathComponent(HotFrameworkReady.fileName)
            guard fm.fileExists(atPath: readyURL.path) else {
                incompleteStagings.append((staging.url, staging.mtime, staging.url.lastPathComponent))
                continue
            }
            guard let readyData = fm.contents(atPath: readyURL.path),
                  let ready = try? JSONDecoder().decode(HotFrameworkReady.self, from: readyData),
                  ready.schema == HotFrameworkReady.currentSchema,
                  isTitleID(ready.titleID.uppercased()) else {
                discardFolder(staging.url, in: hotRoot, fm: fm)
                continue
            }
            let expectedName = "DmGame\(ready.titleID.uppercased()).framework"
            let candidate = staging.url.appendingPathComponent(expectedName, isDirectory: true)
            let stagedFW: URL
            if fm.fileExists(atPath: candidate.path) {
                stagedFW = candidate
            } else if let fwName = ((try? fm.contentsOfDirectory(atPath: staging.url.path)) ?? []).first(where: { $0.hasSuffix(".framework") }) {
                stagedFW = staging.url.appendingPathComponent(fwName, isDirectory: true)
            } else {
                discardFolder(staging.url, in: hotRoot, fm: fm)
                continue
            }
            let entry = readFramework(at: stagedFW, fileManager: fm)
            guard entry.problem == nil,
                  let manifest = entry.manifest,
                  manifest.titleID.caseInsensitiveCompare(ready.titleID) == .orderedSame,
                  let footprint = frameworkFootprint(at: stagedFW, fileManager: fm),
                  footprint.files == ready.files,
                  footprint.bytes == ready.bytes else {
                discardFolder(staging.url, in: hotRoot, fm: fm)
                continue
            }
            let exeURL = stagedFW.appendingPathComponent(manifest.frameworkExecutable)
            guard let exeAttrs = try? fm.attributesOfItem(atPath: exeURL.path),
                  exeAttrs[.type] as? FileAttributeType == .typeRegular,
                  let exeSize = (exeAttrs[.size] as? NSNumber)?.int64Value, exeSize > 0 else {
                discardFolder(staging.url, in: hotRoot, fm: fm)
                continue
            }

            let target = hotRoot.appendingPathComponent(stagedFW.lastPathComponent, isDirectory: true)
            var backup: URL?
            if fm.fileExists(atPath: target.path) {
                let aside = hotRoot.appendingPathComponent(HotFrameworkReady.discardPrefix + UUID().uuidString, isDirectory: true)
                do {
                    try fm.moveItem(at: target, to: aside)
                    backup = aside
                } catch {
                    if !fm.fileExists(atPath: target.path), fm.fileExists(atPath: aside.path) {
                        try? fm.moveItem(at: aside, to: target)
                    }
                    continue
                }
            }
            do {
                try fm.moveItem(at: stagedFW, to: target)
            } catch {
                try? fm.removeItem(at: target)
                if let backup { try? fm.moveItem(at: backup, to: target) }
                continue
            }
            if let backup { try? fm.removeItem(at: backup) }
            try? fm.removeItem(at: staging.url)
            promotedTitles.insert(manifest.titleID.uppercased())
        }

        for item in incompleteStagings {
            let expired = now.timeIntervalSince(item.mtime) >= staleAge
            let superseded = promotedTitles.contains { item.name.uppercased().contains($0) }
            if expired || superseded {
                discardFolder(item.url, in: hotRoot, fm: fm)
            }
        }
    }

    @discardableResult
    public static func discardFolder(_ folder: URL, in parent: URL? = nil, fm: FileManager = .default) -> Bool {
        guard fm.fileExists(atPath: folder.path) else { return true }
        let root = parent ?? folder.deletingLastPathComponent()
        let aside = root.appendingPathComponent(HotFrameworkReady.discardPrefix + UUID().uuidString, isDirectory: true)
        do {
            try fm.moveItem(at: folder, to: aside)
            try? fm.removeItem(at: aside)
            return true
        } catch {
            try? fm.removeItem(at: folder)
            return !fm.fileExists(atPath: folder.path)
        }
    }

    public static func scan(root: URL, hotRoot: URL? = nil, fileManager fm: FileManager = .default) -> [CatalogueEntry] {
        var entries = scanSingleRoot(root, fileManager: fm)
        if let hotRoot {
            promoteStagedFrameworks(in: hotRoot, fileManager: fm)
            let hotEntries = scanSingleRoot(hotRoot, fileManager: fm).filter { $0.directory.pathExtension == "framework" }
            for hot in hotEntries {
                if let idx = entries.firstIndex(where: { $0.id.caseInsensitiveCompare(hot.id) == .orderedSame }) {
                    let bundled = entries[idx]
                    if hot.problem != nil {
                        if bundled.problem == nil {
                            discardFolder(hot.directory, in: hotRoot, fm: fm)
                        } else {
                            entries[idx] = hot
                        }
                        continue
                    }
                    if bundled.problem == nil,
                       let bundledBuilt = bundled.manifest?.builtAt, !bundledBuilt.isEmpty,
                       let hotBuilt = hot.manifest?.builtAt, !hotBuilt.isEmpty,
                       bundledBuilt >= hotBuilt {
                        discardFolder(hot.directory, in: hotRoot, fm: fm)
                        continue
                    }
                    entries[idx] = hot
                } else {
                    entries.append(hot)
                }
            }
        }
        return entries.sorted { ($0.manifest?.name ?? "\u{10FFFF}\($0.id)").localizedCaseInsensitiveCompare($1.manifest?.name ?? "\u{10FFFF}\($1.id)") == .orderedAscending }
    }

    private static func scanSingleRoot(_ root: URL, fileManager fm: FileManager) -> [CatalogueEntry] {
        let names = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        var entries: [CatalogueEntry] = []
        for name in names {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if name.hasSuffix(".framework") {
                // Other frameworks (the Swift runtime, say) can sit next to the games: not a game, not listed.
                guard fm.fileExists(atPath: dir.appendingPathComponent("game.manifest.json").path) else { continue }
                var entry = readFramework(at: dir, fileManager: fm)
                if let first = entries.first(where: { $0.frameworkURL != nil && $0.directory.pathExtension == "framework" && $0.id == entry.id }) {
                    entry = brokenDuplicate(of: first, entry)
                }
                entries.append(entry)
            } else {
                entries.append(read(directory: dir, fileManager: fm))
            }
        }
        return entries
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
            let fwURL = dir.appendingPathComponent(manifest.framework, isDirectory: true)
            entry.frameworkURL = fwURL
            entry.requiresExternalShaders = ExternalShaders.isRequired(in: fwURL, fileManager: fm)
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

    /// An embedded `<Name>.framework`: manifest, launcher.json, pictures and the rest all inside the folder itself.
    public static func readFramework(at fw: URL, fileManager fm: FileManager = .default) -> CatalogueEntry {
        let folder = fw.lastPathComponent
        let fallbackID = String(folder.dropLast(".framework".count))
        let manifestURL = fw.appendingPathComponent("game.manifest.json")
        var entry = CatalogueEntry(id: fallbackID, directory: fw, bannerURL: image(named: "banner", in: fw, fm), iconURL: image(named: "icon", in: fw, fm))
        entry.readableName = lenientName(in: manifestURL, fm)
        do {
            guard let data = fm.contents(atPath: manifestURL.path) else {
                throw GameProblem(cause: .manifestMissing, reason: hostText("Game manifest missing"), detail: hostText("\(folder) has no game.manifest.json."))
            }
            let manifest = try GameManifest.parse(data)
            entry.manifest = manifest
            entry.id = manifest.titleID
            entry.frameworkURL = fw
            entry.requiresExternalShaders = ExternalShaders.isRequired(in: fw, fileManager: fm)
            guard manifest.framework == folder else {
                throw GameProblem(cause: .filesDamaged, reason: hostText("Game files damaged"), detail: hostText("The folder is named \(folder) but the manifest says \(manifest.framework)."))
            }
            let launcherData = fm.contents(atPath: fw.appendingPathComponent(manifest.launcher).path) ?? fm.contents(atPath: fw.appendingPathComponent("launcher.json").path)
            guard let launcherData else {
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
            logger.error("\(folder, privacy: .public): \(problem.reason, privacy: .public): \(problem.detail, privacy: .public)")
        }
        return entry
    }

    /// The second framework with a title ID: broken, naming the one that was kept.
    private static func brokenDuplicate(of first: CatalogueEntry, _ second: CatalogueEntry) -> CatalogueEntry {
        var entry = second
        // A distinct ID keeps both tiles apart (the list and the model look games up by ID).
        entry.id = String(second.directory.lastPathComponent.dropLast(".framework".count))
        entry.problem = GameProblem(cause: .filesDamaged, reason: hostText("Game files damaged"),
                                    detail: hostText("\(second.directory.lastPathComponent) has the same title ID \(second.manifest?.titleID ?? "") as \(first.directory.lastPathComponent), which is used instead."))
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
    /// A folder the player picked for this game, through a bookmark.
    case picked
    /// The data folder the player picked once for every game, in the shell's settings.
    case shell
}

public struct DataResolution: Equatable, Sendable {
    /// The folder holding `romfs.img` or `romfs/<marker>`, or a picked `romfs.img`'s folder.
    public var url: URL?
    public var source: DataSource?
    /// A bookmark exists but no longer resolves (the app is signed differently now).
    public var pickedIsStale: Bool
    /// The image or tree selected within the data folder.
    var romfsURL: URL? = nil
    public var found: Bool { url != nil }
    public static let missing = DataResolution(url: nil, source: nil, pickedIsStale: false)
}

/// The same order as the per-game app's `romfs_locate` (dm/ios/Sources/main.m): the picked location first, then the
/// app's `Documents/games/<title ID>/`, each accepted only when it holds the game's image or marker. It differs by the
/// `<picked>/<title ID>/` subfolder fallback (matching the launchers' Copy to drive export layout when the player picks
/// the drive root for one game) and by the shell-level folder, which the per-game app has no counterpart for: one folder
/// serves every game. The order is the game's own pick (`<picked>` then `<picked>/<title ID>/` in any letter case), then
/// in the shell folder `shellMatch` (the folder of the image with the game's identity, found by `ShellDataIndex` whatever
/// the folder is called), `<folder>/<title ID>/` by name, the folder itself (the layout for a single game), and last the
/// app's folder. All shell folder cases say `.shell`.
public enum DataLocator {
    public static func locate(manifest: GameManifest, picked: BookmarkResolution, appFolder: URL, fileManager fm: FileManager = .default,
                              global: BookmarkResolution = .none, shellMatch: URL? = nil) -> DataResolution {
        locate(manifest: manifest, picked: picked, appFolder: appFolder, fileManager: fm, global: global, shellMatch: shellMatch) {
            RomfsIdentity.ofImage(at: $0) == $1
        }
    }

    static func locate(manifest: GameManifest, picked: BookmarkResolution, appFolder: URL, fileManager fm: FileManager = .default,
                       global: BookmarkResolution, shellMatch: URL?, matchesIdentity: (URL, RomfsIdentity) -> Bool) -> DataResolution {
        var result = DataResolution.missing
        let expectedIdentity = RomfsIdentity.parse(manifest.romfsIdentity)
        func select(_ url: URL, source: DataSource, allowFile: Bool? = nil) -> Bool {
            guard let candidate = romfs(in: url, manifest: manifest, fm, allowPickedFile: allowFile ?? (source == .picked), acceptsImage: { image in
                guard source != .app, let expectedIdentity else { return true }
                return matchesIdentity(image, expectedIdentity)
            }) else { return false }
            result.url = candidate.folder
            result.romfsURL = candidate.romfs
            result.source = source
            return true
        }
        switch picked {
        case .stale: result.pickedIsStale = true
        case .url(let url):
            if select(url, source: .picked) { return result }
            for titleFolder in titleFolders(in: url, titleID: manifest.titleID, fm) where select(titleFolder, source: .picked, allowFile: false) {
                return result
            }
        case .none: break
        }
        switch global {   // the shell-level data folder: the game's own bookmark wins, this backs it up
        case .url(let url):
            if let match = shellMatch, select(match, source: .shell) { return result }
            for titleFolder in titleFolders(in: url, titleID: manifest.titleID, fm) where select(titleFolder, source: .shell) {
                return result
            }
            if select(url, source: .shell) { return result }
        case .stale, .none: break
        }
        _ = select(appFolder, source: .app)
        return result
    }

    /// `<folder>/<title ID>/` in any letter case of the hex ID, exact match first (Windows DriveCopy writes uppercase, a hand-named
    /// folder may be lowercase, and iOS APFS is case-sensitive). Symbolic links and plain files are skipped.
    static func titleFolders(in url: URL, titleID: String, _ fm: FileManager) -> [URL] {
        var isDir: ObjCBool = false
        guard !titleID.isEmpty, fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return [] }
        let entries = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
        let exact = entries.contains(titleID) ? [titleID] : []
        let otherCase = entries.filter { $0 != titleID && $0.caseInsensitiveCompare(titleID) == .orderedSame }.sorted()
        return (exact + otherCase).compactMap { name in
            let child = url.appendingPathComponent(name, isDirectory: true)
            guard let attrs = try? fm.attributesOfItem(atPath: child.path),
                  attrs[.type] as? FileAttributeType == .typeDirectory else { return nil }
            return child
        }
    }

    /// The exact image or tree and its data folder, where add-on content lives.
    static func romfs(in url: URL, manifest: GameManifest, _ fm: FileManager, allowPickedFile: Bool = false,
                      acceptsImage: (URL) -> Bool = { _ in true }) -> (folder: URL, romfs: URL)? {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue {
            guard allowPickedFile, url.pathExtension.lowercased() == "img", isComplete(url, manifest: manifest, fm), acceptsImage(url)
            else { return nil }
            return (url.deletingLastPathComponent(), url)
        }
        let canonicalImage = url.appendingPathComponent("romfs.img")
        if isComplete(canonicalImage, manifest: manifest, fm), acceptsImage(canonicalImage) { return (url, canonicalImage) }
        let names = ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).filter { $0 != "romfs.img" && $0.lowercased() == "romfs.img" }
        for name in names.sorted() {
            let image = url.appendingPathComponent(name)
            if isComplete(image, manifest: manifest, fm), acceptsImage(image) { return (url, image) }
        }
        for tree in [url.appendingPathComponent("romfs", isDirectory: true), url]
        where fm.fileExists(atPath: tree.appendingPathComponent(manifest.romfsMarker).path) { return (url, tree) }
        return nil
    }

    /// A non-empty image, and when the manifest names the image it was built for (`romfs_identity`, `size=<bytes>`), exactly that
    /// size: a copy cut off partway (the device locked or was unplugged during the Mac launcher's copy) is not game data yet.
    static func isComplete(_ url: URL, manifest: GameManifest, _ fm: FileManager) -> Bool {
        guard let attributes = try? fm.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType != .typeDirectory,
              let size = (attributes[.size] as? NSNumber)?.int64Value, size > 0 else { return false }
        return expectedImageSize(manifest).map { $0 == size } ?? true
    }

    /// `size=<bytes>` of the manifest's `romfs_identity` line (`DMROMFSID1 title=… size=… index=…`), nil without one.
    static func expectedImageSize(_ manifest: GameManifest) -> Int64? {
        manifest.romfsIdentity.split(separator: " ").first { $0.hasPrefix("size=") }.flatMap { Int64($0.dropFirst(5)) }
    }
}

/// Derives the state a tile shows from what is present: a bundle that cannot run is broken with its reason, a game
/// built for another chain (when its framework has no host of its own) or a newer OS needs an app update, a game without reachable data needs game data.
public enum GameStateResolver {
    public static func state(for entry: CatalogueEntry, data: DataResolution, environment: HostEnvironment) -> GameState {
        if let problem = entry.problem { return problem.state }
        guard let manifest = entry.manifest else { return GameProblem(cause: .manifestMissing, reason: hostText("Game manifest missing")).state }
        if manifest.loader != "FH", let chain = environment.chain, chain != manifest.chain { return .needsAppUpdate }
        if let min = manifest.minOSVersion, !isVersion(environment.osVersion, atLeast: min) { return .needsAppUpdate }
        return data.found ? .playable : .needsGameData
    }
}
