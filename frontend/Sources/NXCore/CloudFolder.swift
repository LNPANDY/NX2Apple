import Foundation

/// A folder that a cloud service syncs: iCloud Drive (`~/Library/Mobile Documents`), a File Provider cloud folder
/// (`~/Library/CloudStorage`: OneDrive, Google Drive, Dropbox), or a folder iCloud syncs from elsewhere, such as Desktop and
/// Documents when they are turned on in iCloud Drive. The service adds extended attributes to the files in it. codesign refuses
/// them ("resource fork, Finder information, or similar detritus not allowed"), so a build folder there fails at its last step,
/// often after an hour (issue #263).
package enum CloudFolder {
    /// The folders under the home folder that are cloud folders by their place.
    package static let homeRoots = ["Library/Mobile Documents", "Library/CloudStorage"]

    /// Whether `path` is in a cloud folder. The path may not exist yet (a build folder is made by the build): the nearest folder
    /// above it that exists decides. Symlinks are resolved first, so a link to a cloud folder counts as one.
    /// `isSynced` answers for an existing folder that is not in a root: the default asks the system whether iCloud syncs it.
    package static func contains(_ path: String, home: String = NSHomeDirectory(),
                         isSynced: (URL) -> Bool = CloudFolder.systemSyncs) -> Bool {
        guard !path.isEmpty else { return false }
        let here = resolved(path)
        for root in homeRoots.map({ resolved(home + "/" + $0) }) where here == root || here.hasPrefix(root + "/") { return true }
        return isSynced(URL(fileURLWithPath: nearestExisting(here)))
    }

    /// iCloud's own answer for a file or folder: true when it is in an iCloud container, which includes Desktop and Documents
    /// while they are synced.
    package static func systemSyncs(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem ?? false
    }

    private static func nearestExisting(_ path: String) -> String {
        var url = URL(fileURLWithPath: path)
        while url.path != "/", !FileManager.default.fileExists(atPath: url.path) { url.deleteLastPathComponent() }
        return url.path
    }

    /// The path with its symlinks resolved as far as it exists, and the rest of it as written.
    private static func resolved(_ path: String) -> String {
        let existing = nearestExisting(path)
        let base = URL(fileURLWithPath: existing).resolvingSymlinksInPath().path
        let rest = String(URL(fileURLWithPath: path).standardized.path.dropFirst(URL(fileURLWithPath: existing).standardized.path.count))
        return rest.isEmpty ? base : (base == "/" ? "" : base) + rest
    }
}
