import Foundation

// LNPANDY/NX2Apple#427: the shared app's folder (frameworks, shell.json, banner cache) used to sit inside the game output folder,
// the one place a player cleans. It now lives in ~/Library/Application Support/NX2Apple/shell. An old install moves once, and
// only when that is safe: the folder is the one the launcher made itself (`NX2Apple-shell`), it is a plain folder with a readable
// shell.json, the new place is free and on the same volume, so the move is a rename and never a copy. On any doubt the old folder
// stays where it is and keeps being used. Nothing is deleted.

package enum ShellRootMigration {
    /// The name of the folder older versions made inside the output folder.
    package static let legacyName = "NX2Apple-shell"

    /// `~/Library/Application Support/NX2Apple/shell`, next to the engine trees.
    package static func defaultRoot(home: String = NSHomeDirectory()) -> String {
        home + "/Library/Application Support/NX2Apple/shell"
    }

    /// Whether a root is one this launcher made inside an output folder, which is the only kind that moves. A root the player
    /// chose themselves (any other name) stays.
    package static func isLegacy(_ root: String, home: String = NSHomeDirectory()) -> Bool {
        (root as NSString).lastPathComponent == legacyName && root != defaultRoot(home: home)
    }

    /// At launch: a saved root of the old kind moves now, so every screen shows the same folder from the start.
    package static func migrateSavedRoot(defaults: UserDefaults = .standard, home: String = NSHomeDirectory()) {
        guard let saved = defaults.string(forKey: "shellRoot"), isLegacy(saved, home: home),
              !defaults.bool(forKey: ShellRootMove.pickedKey) else { return }
        _ = ShellLibrary.resolveRoot(defaults: defaults, parent: "", home: home)
    }

    package enum Outcome: Equatable {
        /// The folder moved and shell.json now names the new place.
        case moved
        /// There was no folder to move (a player deleted it), so the new place is simply used.
        case nothingToMove
        /// The old folder stays and keeps being used. The text says why (for the log and the tests).
        case left(String)
    }

    /// Moves `old` to `new` when that is safe, see the file's header. `new` must not exist.
    package static func migrate(from old: String, to new: String, fm: FileManager = .default) -> Outcome {
        guard fm.fileExists(atPath: old) || (try? fm.destinationOfSymbolicLink(atPath: old)) != nil else {
            // Gone from a folder that is there: a player deleted it. Gone with its folder (an external drive that is not
            // mounted): it may come back, so it stays the saved root.
            return fm.fileExists(atPath: (old as NSString).deletingLastPathComponent) ? .nothingToMove : .left("its folder is not there")
        }
        // A symbolic link, a file or an alias is not the folder we made: leave it.
        guard let type = (try? fm.attributesOfItem(atPath: old))?[.type] as? FileAttributeType, type == .typeDirectory,
              (try? fm.destinationOfSymbolicLink(atPath: old)) == nil else { return .left("not a plain folder") }
        guard !fm.fileExists(atPath: new), (try? fm.destinationOfSymbolicLink(atPath: new)) == nil else { return .left("the new place exists") }
        guard let entries = try? fm.contentsOfDirectory(atPath: old) else { return .left("cannot be read") }
        let stateFile = ShellLibrary.stateFile(root: old)
        if entries.contains("shell.json") {
            guard let data = fm.contents(atPath: stateFile), (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                return .left("shell.json cannot be read")
            }
        } else if !entries.filter({ $0 != ".DS_Store" }).isEmpty {
            return .left("no shell.json, so not a shell folder we know")
        }
        let parent = (new as NSString).deletingLastPathComponent
        do { try fm.createDirectory(atPath: parent, withIntermediateDirectories: true) } catch { return .left("cannot make \(parent)") }
        guard sameVolume(old, parent) else { return .left("another volume") }
        do { try fm.moveItem(atPath: old, toPath: new) } catch { return .left("cannot move: \(error.localizedDescription)") }
        guard rewritePaths(root: new, from: old, to: new, fm: fm) else {
            // The ledger still names the old place. Put everything back rather than leave a split state.
            if (try? fm.moveItem(atPath: new, toPath: old)) == nil { return .left("moved, but shell.json could not be rewritten") }
            return .left("shell.json could not be rewritten")
        }
        return .moved
    }

    /// shell.json's framework paths that lie inside the old root now lie inside the new one. A framework in a build folder, and
    /// every other key, stay as they are. The file is read as plain JSON so a key this version does not know is not lost.
    package static func rewritePaths(root: String, from old: String, to new: String, fm: FileManager = .default) -> Bool {
        let file = ShellLibrary.stateFile(root: root)
        guard fm.fileExists(atPath: file) else { return true }
        guard let data = fm.contents(atPath: file), var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        var games = json["games"] as? [[String: Any]] ?? []
        for i in games.indices {
            if let path = games[i]["framework"] as? String, path.hasPrefix(old + "/") { games[i]["framework"] = new + path.dropFirst(old.count) }
        }
        if json["games"] != nil { json["games"] = games }
        guard let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return false }
        return (try? out.write(to: URL(fileURLWithPath: file), options: .atomic)) != nil
    }

    private static func sameVolume(_ a: String, _ b: String) -> Bool {
        let key = URLResourceKey.volumeIdentifierKey
        guard let x = try? URL(fileURLWithPath: a).resourceValues(forKeys: [key]).volumeIdentifier,
              let y = try? URL(fileURLWithPath: b).resourceValues(forKeys: [key]).volumeIdentifier else { return false }
        return x.isEqual(y)
    }
}
