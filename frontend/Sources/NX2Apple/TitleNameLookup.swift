import Foundation
import NXCore

/// The game's names for a library entry whose app carries no `DMTitleNames` (packed before the engine wrote the key, or not built yet),
/// so no game has to be built again for its name to follow the launcher's language (LNPANDY/NX2Apple#895). From the game's own
/// control data, offline, in this order:
/// 1. a `control.nacp` an earlier build left in its build folder (`<title ID>_build/extract/v<version>/`, the NSP script's),
/// 2. the base game's package (NSP, NSZ, XCI, XCZ) with the game folder's keys or the saved keys: `PackageControl` reads the control data alone, a few
///    kilobytes, where an extraction takes minutes. No engine tool is needed.
/// A game with neither (the package deleted, no keys or keys too old for it) keeps showing the bundle name. Blocking: call it off the main thread.
enum TitleNameLookup {
    /// The names from the game's control data, nil when none could be read.
    static func names(for game: LibraryGame, fallbackKeys: String = "", fm: FileManager = .default) -> [String: String]? {
        if let leftover = leftoverControl(for: game, fm: fm), let data = try? Data(contentsOf: leftover) {
            let names = GameTitleNames.names(nacp: data)
            if !names.isEmpty { return names }
        }
        guard let package = packageFile(of: game, fm: fm) else { return nil }
        let tid = UInt64(game.titleID, radix: 16)
        for keys in candidateKeys(of: game, fallbackKeys: fallbackKeys, fm: fm) {
            guard let data = PackageControl.read(package: package, keysFile: keys, titleID: tid) else { continue }
            let names = GameTitleNames.names(nacp: data)
            if !names.isEmpty { return names }
        }
        return nil
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
    static func packageInputs(of game: LibraryGame, fallbackKeys: String = "", fm: FileManager = .default) -> (keys: String, package: String)? {
        guard let package = packageFile(of: game, fm: fm),
              let keys = candidateKeys(of: game, fallbackKeys: fallbackKeys, fm: fm).first else { return nil }
        return (keys, package)
    }

    static func packageFile(of game: LibraryGame, fm: FileManager = .default) -> String? {
        guard let package = game.inputs["base"]?.first, !package.isEmpty,
              ["nsp", "nsz", "xci", "xcz"].contains((package as NSString).pathExtension.lowercased()) else { return nil }
        var dir: ObjCBool = false
        guard fm.fileExists(atPath: package, isDirectory: &dir), !dir.boolValue else { return nil }
        return package
    }

    static func candidateKeys(of game: LibraryGame, fallbackKeys: String = "", fm: FileManager = .default) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        for candidate in [(game.inputs["keys"]?.first ?? ""), fallbackKeys] where !candidate.isEmpty {
            var dir: ObjCBool = false
            guard fm.fileExists(atPath: candidate, isDirectory: &dir), !dir.boolValue else { continue }
            let canonical = URL(fileURLWithPath: candidate).standardizedFileURL.path
            if seen.insert(canonical).inserted { result.append(candidate) }
        }
        return result
    }

    /// Fingerprint of the inputs that affect a title-name lookup, so configuring `prod.keys` or finishing a package copy retries automatically.
    static func attemptSignature(for game: LibraryGame, fallbackKeys: String = "", fm: FileManager = .default) -> String {
        let leftover = leftoverControl(for: game, fm: fm)?.path ?? ""
        let localKeys = game.inputs["keys"]?.first ?? ""
        let package = game.inputs["base"]?.first ?? ""
        return [
            game.titleID.uppercased(),
            fileSignature(leftover, fm: fm),
            fileSignature(localKeys, fm: fm),
            fileSignature(fallbackKeys, fm: fm),
            fileSignature(package, fm: fm),
        ].joined(separator: "\n")
    }

    private static func fileSignature(_ path: String, fm: FileManager) -> String {
        guard !path.isEmpty else { return "" }
        var dir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &dir), !dir.boolValue,
              let attr = try? fm.attributesOfItem(atPath: path) else { return "" }
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
        let inode = attr[.systemFileNumber] as? UInt64 ?? 0
        let size = attr[.size] as? UInt64 ?? 0
        let mtime = (attr[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(canonical)|\(inode)|\(size)|\(String(format: "%.6f", mtime))"
    }
}

extension GameLibrary {
    /// Looks up the names of the games that have none, in the background, one game at a time, and keeps what it finds. Each input
    /// state is tried once: configuring keys or replacing an incomplete package changes the signature and allows a fresh lookup.
    func fillMissingTitleNames() {
        let fallbackKeys = keysFile()
        let wanted: [(game: LibraryGame, signature: String)] = games.compactMap { game in
            guard game.titleNames.isEmpty, !game.titleID.hasPrefix("/") else { return nil }
            let sig = TitleNameLookup.attemptSignature(for: game, fallbackKeys: fallbackKeys)
            guard TitleNameAttempts.shared.begin(sig) else { return nil }
            return (game, sig)
        }
        guard !wanted.isEmpty else { return }
        TitleNameAttempts.queue.async { [weak self] in
            for item in wanted {
                let currentSig = TitleNameLookup.attemptSignature(for: item.game, fallbackKeys: fallbackKeys)
                let names = TitleNameLookup.names(for: item.game, fallbackKeys: fallbackKeys)
                TitleNameAttempts.shared.finish(item.signature, recordCompleted: currentSig == item.signature)
                guard let names else { continue }
                DispatchQueue.main.async {
                    guard let self,
                          let existing = self.games.first(where: { $0.id == item.game.id }),
                          existing.titleID == item.game.titleID,
                          existing.titleNames.isEmpty else { return }
                    self.setTitleNames(names, for: item.game.id)
                }
            }
        }
    }
}

/// Input signatures looked up this launch, and the serial queue the lookups run on one after another.
enum TitleNameAttempts {
    static let queue = DispatchQueue(label: "nx2apple.title-names", qos: .utility)
    static let shared = LockedSet()

    final class LockedSet: @unchecked Sendable {
        private let lock = NSLock()
        private var completed: Set<String> = []
        private var inFlight: Set<String> = []

        func contains(_ signature: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return completed.contains(signature) || inFlight.contains(signature)
        }

        func insert(_ signature: String) {
            lock.lock()
            completed.insert(signature)
            lock.unlock()
        }

        func begin(_ signature: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !completed.contains(signature), !inFlight.contains(signature) else { return false }
            inFlight.insert(signature)
            return true
        }

        func finish(_ signature: String, recordCompleted: Bool = true) {
            lock.lock()
            inFlight.remove(signature)
            if recordCompleted { completed.insert(signature) }
            lock.unlock()
        }

        func reset() {
            lock.lock()
            completed.removeAll()
            inFlight.removeAll()
            lock.unlock()
        }
    }
}
