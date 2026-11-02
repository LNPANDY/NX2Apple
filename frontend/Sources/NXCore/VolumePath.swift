import Foundation

package enum VolumePath {
    /// A path on an external volume (`/Volumes/<name>/...`) whose mount point is absent: the drive is not connected, so the file is
    /// not known to be gone and its path must stay.
    package static func onUnmounted(_ path: String, volumes: String = "/Volumes") -> Bool {
        let prefix = volumes.hasSuffix("/") ? volumes : volumes + "/"
        guard path.hasPrefix(prefix), let name = path.dropFirst(prefix.count).split(separator: "/").first else { return false }
        return !FileManager.default.fileExists(atPath: prefix + name)
    }
}
