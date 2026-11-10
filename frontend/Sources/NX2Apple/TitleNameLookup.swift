import Foundation
import NXCore

/// The game's names for a library entry whose app carries no `DMTitleNames` (packed before the engine wrote the key, or not built yet),
/// so no game has to be built again for its name to follow the launcher's language (LNPANDY/NX2Apple#895). From the game's own
/// control data, offline, in this order:
/// 1. a `control.nacp` an earlier build left in its build folder (`<title ID>_build/extract/v<version>/`, the NSP script's),
/// 2. the base game's package (NSP, NSZ, XCI, XCZ) with the player's keys: `PackageControl` reads the control data alone, a few
///    kilobytes, where an extraction takes minutes. No engine tool is needed.
/// A game with neither (the package deleted, no keys or keys too old for it) keeps showing the bundle name. Blocking: call it off the main thread.
enum TitleNameLookup {
    /// The names from the game's control data, nil when none could be read.
    static func names(for game: LibraryGame) -> [String: String]? {
        if let leftover = leftoverControl(for: game), let data = try? Data(contentsOf: leftover) {
            let names = GameTitleNames.names(nacp: data)
            if !names.isEmpty { return names }
        }
        guard let (keys, package) = packageInputs(of: game),
              let data = PackageControl.read(package: package, keysFile: keys, titleID: UInt64(game.titleID, radix: 16)) else { return nil }
        let names = GameTitleNames.names(nacp: data)
        return names.isEmpty ? nil : names
    }

    /// The control data a build of this game left in its build folder: beside the base package (the NSP script's default), in the
    /// output folder or in the game's folder. The highest version's, as the build reads it.
    static func leftoverControl(for game: LibraryGame, fm: FileManager = .default) -> URL? {
        var folders: [String] = [game.outputDirectory, game.sourceFolder, (game.appPath as NSString).deletingLastPathComponent]
        folders += (game.inputs["base"] ?? []).map { ($0 as NSString).deletingLastPathComponent }
        for folder in folders where !folder.isEmpty {
            let extract = URL(fileURLWithPath: folder).appendingPathComponent(game.titleID + "_build/extract", isDirectory: true)
            guard let versions = try? fm.contentsOfDirectory(atPath: extract.path) else { continue }
            let found = versions.filter { $0.hasPrefix("v") }
                .sorted { (Int($0.dropFirst()) ?? -1) > (Int($1.dropFirst()) ?? -1) }
                .map { extract.appendingPathComponent($0 + "/control.nacp") }
                .first { fm.fileExists(atPath: $0.path) }
            if let found { return found }
        }
        return nil
    }

    /// The keys file and the base game's package when both are files on disk. A game folder (a Switch 2 game's) or a NUP has no package to read.
    static func packageInputs(of game: LibraryGame, fm: FileManager = .default) -> (keys: String, package: String)? {
        guard let keys = game.inputs["keys"]?.first, let package = game.inputs["base"]?.first,
              ["nsp", "nsz", "xci", "xcz"].contains((package as NSString).pathExtension.lowercased()) else { return nil }
        var dir: ObjCBool = false
        guard fm.fileExists(atPath: keys), fm.fileExists(atPath: package, isDirectory: &dir), !dir.boolValue else { return nil }
        return (keys, package)
    }
}

extension GameLibrary {
    /// Looks up the names of the games that have none, in the background, one game at a time, and keeps what it finds. Each game is
    /// tried once per launch: a game whose package is gone is not read again on every library change.
    func fillMissingTitleNames() {
        let wanted = games.filter { $0.titleNames.isEmpty && !$0.titleID.hasPrefix("/") && !TitleNameAttempts.shared.contains($0.titleID) }
        guard !wanted.isEmpty else { return }
        wanted.forEach { TitleNameAttempts.shared.insert($0.titleID) }
        TitleNameAttempts.queue.async {
            for game in wanted {
                guard let names = TitleNameLookup.names(for: game) else { continue }
                DispatchQueue.main.async { self.setTitleNames(names, for: game.id) }
            }
        }
    }
}

/// The games looked up this launch (by title ID), and the queue the lookups run on one after another.
enum TitleNameAttempts {
    static let queue = DispatchQueue(label: "nx2apple.title-names", qos: .utility)
    static let shared = LockedSet()

    final class LockedSet: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: Set<String> = []
        func contains(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return ids.contains(id) }
        func insert(_ id: String) { lock.lock(); ids.insert(id); lock.unlock() }
    }
}
