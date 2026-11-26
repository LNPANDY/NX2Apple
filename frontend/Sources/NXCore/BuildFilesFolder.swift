import Foundation

/// Where a game's build files go (`<folder>/<title ID>_build`: the extracted game, the rewritten code, the shader cache) when the
/// player keeps them apart from the finished app. A build on an external drive leaves the app on the Mac, which plays without the
/// drive, and the drive is needed again only to update or rebuild the game. Pure rules, so they are tested without a store.
package enum BuildFilesFolder {
    /// The preference that holds the chosen folder. Empty or absent: the build files sit beside the app, as before the setting.
    package static let key = "buildFilesDirectory"

    /// The chosen folder, trimmed. Empty when the player did not choose one.
    package static func chosen(_ defaults: UserDefaults = .standard) -> String {
        (defaults.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The folder that holds `<key>_build`: the chosen build-files folder, else the app's folder.
    package static func root(chosen: String, appFolder: String) -> String {
        let chosen = chosen.trimmingCharacters(in: .whitespacesAndNewlines)
        return chosen.isEmpty ? appFolder : chosen
    }

    /// `<root>/<key>_build`, or empty without a root.
    package static func workDir(root: String, key: String) -> String {
        root.isEmpty ? "" : (root as NSString).appendingPathComponent(key + "_build")
    }

    /// The places a game's build folder can be, first the chosen build-files folder, then the folders the launcher used before
    /// the setting (the app's folder, beside the game files). `suffixes` adds the engines' own folders in each place
    /// (`<key>_mng_build`, EngineUpstreamKind.workDirSuffix). Duplicates and empty folders are dropped.
    package static func candidates(key: String, chosen: String, others: [String], suffixes: [String] = [""]) -> [String] {
        var seen = Set<String>()
        return ([chosen] + others)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .flatMap { root in suffixes.map { workDir(root: root, key: key + $0) } }
            .filter { seen.insert(($0 as NSString).standardizingPath).inserted }
    }

    /// True when `path` is on an external drive (`/Volumes/<name>/…`) that is not connected. A folder that only looks like a
    /// mount point counts as not connected too: with the drive gone, `/Volumes/<name>` can be a plain folder on the Mac's own disk
    /// (made by a tool that wrote there), and a build into it would fill the Mac's disk instead of the drive.
    package static func driveMissing(_ path: String, volumes: String = "/Volumes") -> Bool {
        let prefix = volumes.hasSuffix("/") ? volumes : volumes + "/"
        guard path.hasPrefix(prefix), let name = path.dropFirst(prefix.count).split(separator: "/").first else { return false }
        let mountPoint = prefix + name
        if VolumePath.onUnmounted(path, volumes: volumes) { return true }
        guard volumes == "/Volumes" else { return false }   // tests use a plain folder as /Volumes
        return mountPointOf(mountPoint) != mountPoint
    }

    /// The mount point of the volume that holds `path` (statfs), nil when it cannot be read.
    static func mountPointOf(_ path: String) -> String? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        return withUnsafePointer(to: &info.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    /// The name of the drive a path is on (`/Volumes/<name>/…`), for the message that asks to connect it.
    package static func driveName(_ path: String, volumes: String = "/Volumes") -> String? {
        let prefix = volumes.hasSuffix("/") ? volumes : volumes + "/"
        guard path.hasPrefix(prefix), let name = path.dropFirst(prefix.count).split(separator: "/").first else { return nil }
        return String(name)
    }
}
