import Foundation

// Step 3 of the export for every game of the shared app (LNPANDY/NX2Apple#994): where each game's data folder is on this Mac. A build
// records it in shell.json now. A game built before that is found where the archive step writes it, from what the launcher's library
// remembers of the game (its folder, its output folder, its inputs).

package enum ShellGameData {
    /// A game's data folder: `games/<title ID>` with its romfs.img (and aoc/ beside it).
    package static func isDataFolder(_ path: String, fm: FileManager = .default) -> Bool {
        !path.isEmpty && fm.fileExists(atPath: path + "/romfs.img")
    }

    /// The folders the data of `titleID` can be in, best first: `recorded` (an archive folder the library knows), then `games/<title ID>`
    /// in each of `parents` (the build's output folder, else the folder of its inputs, as `packArchive` writes it). No duplicates.
    package static func candidates(titleID: String, recorded: [String], parents: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for path in recorded + parents.filter { !$0.isEmpty }.map({ $0 + "/games/" + titleID }) where !path.isEmpty && seen.insert(path).inserted {
            out.append(path)
        }
        return out
    }

    /// A folder that holds only a game's shaders (`msl/`): the export moved them there and the game's romfs.img is gone from this Mac
    /// (the device may hold it already). Step 3 still sends them.
    package static func hasShaders(_ path: String, fm: FileManager = .default) -> Bool {
        var directory: ObjCBool = false
        return !path.isEmpty && fm.fileExists(atPath: path + "/msl", isDirectory: &directory) && directory.boolValue
    }

    /// The first of `candidates` that holds the data, else the first that holds the game's shaders, nil when none does.
    package static func folder(in candidates: [String], fm: FileManager = .default) -> String? {
        candidates.first { isDataFolder($0, fm: fm) } ?? candidates.first { hasShaders($0, fm: fm) }
    }
}
